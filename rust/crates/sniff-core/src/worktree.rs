//! Git worktree inspection, revalidation and removal.
//!
//! Worktrees are found through `git worktree list`, never by guessing. Only
//! linked worktrees are candidates; the primary checkout and every branch are
//! preserved. Git runs with hooks, fsmonitor and clean/process filters
//! disabled, without fetching, and only reads locally recorded references.

use crate::catalog::Catalog;
use crate::command;
use crate::fsx::{self, build_manifest, EntryKind, Manifest, RemovalReport, RemovalStop, WalkOptions};
use crate::model::*;
use crate::paths::{canonical, contains, has_symlink_ancestor, to_string};
use crate::procs::ProcessInventory;
use std::collections::{BTreeSet, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const ADMIN_LIMIT: usize = 200;
pub const GIT: &str = "/usr/bin/git";
const GIT_TIMEOUT: Duration = Duration::from_secs(12);

const METADATA_FILES: &[&str] = &[
    "",
    "HEAD",
    "index",
    "ORIG_HEAD",
    "COMMIT_EDITMSG",
    "commondir",
    "gitdir",
    "logs",
    "logs/HEAD",
    "refs",
];
const METADATA_DIRS: &[&str] = &["", "logs", "refs"];
const IN_PROGRESS: &[&str] = &[
    "locked",
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "rebase-apply",
    "rebase-merge",
    "sequencer",
    "BISECT_LOG",
    "BISECT_START",
];

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Record {
    pub path: String,
    pub head: Option<String>,
    pub branch: Option<String>,
    pub locked: bool,
    pub bare: bool,
}

pub fn parse_records(output: &str) -> Vec<Record> {
    output
        .split("\0\0")
        .filter_map(|block| {
            let mut fields = block.split('\0').filter(|f| !f.is_empty());
            let first = fields.next()?;
            let mut r = Record {
                path: first.strip_prefix("worktree ")?.to_string(),
                ..Default::default()
            };
            for f in fields {
                if let Some(h) = f.strip_prefix("HEAD ") {
                    r.head = Some(h.to_string());
                } else if let Some(b) = f.strip_prefix("branch ") {
                    r.branch = Some(b.to_string());
                } else if f == "locked" || f.starts_with("locked ") {
                    r.locked = true;
                } else if f == "bare" {
                    r.bare = true;
                }
            }
            Some(r)
        })
        .collect()
}

pub fn git(path: &Path, args: &[&str]) -> command::Output {
    let p = to_string(path);
    let mut argv: Vec<String> = [
        "--no-pager",
        "--no-optional-locks",
        "--no-replace-objects",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "core.trustctime=true",
        "-c",
        "core.checkStat=default",
        "-c",
        "core.ignoreStat=false",
        "-c",
        "core.fileMode=true",
        "-c",
        "color.ui=false",
        "-c",
        "status.submoduleSummary=false",
        "-c",
        "protocol.allow=never",
        "-C",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    argv.push(p);
    if args.first() == Some(&"status") {
        // Clean/process filters are executable commands configured by the
        // repository or user. Never run them while inspecting a project.
        let filters = git(
            path,
            &[
                "config",
                "--null",
                "--name-only",
                "--get-regexp",
                r"^filter\..*\.(clean|process|required)$",
            ],
        );
        let names = fields(&filters.text());
        if filters.timed_out || !(filters.status == 0 || filters.status == 1) || names.len() > 100 {
            return command::Output {
                status: -1,
                stdout: Vec::new(),
                timed_out: filters.timed_out,
            };
        }
        for n in names {
            argv.push("-c".into());
            argv.push(if n.ends_with(".required") {
                format!("{n}=false")
            } else {
                format!("{n}=")
            });
        }
    }
    argv.extend(args.iter().map(|s| s.to_string()));
    let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
    command::run(Path::new(GIT), &refs, None, GIT_TIMEOUT)
}

#[derive(Debug)]
pub struct GitError;

fn checked(path: &Path, args: &[&str]) -> Result<String, GitError> {
    let out = git(path, args);
    if out.ok() {
        Ok(out.text())
    } else {
        Err(GitError)
    }
}

pub fn line(s: &str) -> String {
    s.strip_suffix('\n').unwrap_or(s).to_string()
}

pub fn fields(s: &str) -> Vec<String> {
    s.split('\0').filter(|f| !f.is_empty()).map(str::to_string).collect()
}

fn count(path: &Path, revisions: &[&str]) -> Result<u64, GitError> {
    let mut args = vec!["rev-list", "--count"];
    args.extend_from_slice(revisions);
    args.push("--");
    line(&checked(path, &args)?).trim().parse().map_err(|_| GitError)
}

/// Reads a small regular UTF-8 file reached without symlinks.
fn bounded_text(path: &Path, limit: u64) -> Result<String, GitError> {
    use rustix::fs::{openat, Mode, OFlags};
    let (parent, name) = fsx::open_parent_nofollow(path).map_err(|_| GitError)?;
    let fd = openat(
        &parent,
        name.as_c_str(),
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| GitError)?;
    let st = rustix::fs::fstat(&fd).map_err(|_| GitError)?;
    if EntryKind::from_stat(&st) != EntryKind::File || st.st_size < 0 || st.st_size as u64 > limit {
        return Err(GitError);
    }
    let mut buf = Vec::new();
    std::io::Read::read_to_end(&mut std::fs::File::from(fd), &mut buf).map_err(|_| GitError)?;
    String::from_utf8(buf).map_err(|_| GitError)
}

fn exists(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

pub fn regenerable(rel: &str, tracked: &HashSet<String>) -> bool {
    let parts: Vec<&str> = rel.split('/').filter(|p| !p.is_empty()).collect();
    for (i, part) in parts.iter().enumerate() {
        let prefix = parts[..i].join("/");
        let base = if prefix.is_empty() {
            String::new()
        } else {
            format!("{prefix}/")
        };
        let has = |f: &str| tracked.contains(&format!("{base}{f}"));
        if ["node_modules", ".next", ".nuxt"].contains(part) && has("package.json") {
            return true;
        }
        if *part == "target" && has("Cargo.toml") {
            return true;
        }
        if *part == ".build" && has("Package.swift") {
            return true;
        }
        if ["bin", "obj"].contains(part)
            && tracked.iter().any(|t| {
                let p = Path::new(t);
                let dir = p.parent().map(to_string).unwrap_or_default();
                dir == prefix
                    && p.extension()
                        .and_then(|e| e.to_str())
                        .is_some_and(|e| ["csproj", "fsproj", "vbproj"].contains(&e))
            })
        {
            return true;
        }
    }
    false
}

pub fn sensitive(rel: &str) -> bool {
    const NAMES: &[&str] = &[
        ".git",
        ".claude",
        ".codex",
        ".wrangler",
        ".ssh",
        ".aws",
        ".config",
        ".proposta-web-local",
        ".npmrc",
        ".pypirc",
        ".netrc",
        "credentials",
        ".gnupg",
        ".direnv",
        ".terraform",
    ];
    let comps: Vec<String> = rel
        .split('/')
        .filter(|p| !p.is_empty())
        .map(|c| c.to_lowercase())
        .collect();
    if comps
        .iter()
        .any(|c| NAMES.contains(&c.as_str()) || c.starts_with(".env"))
    {
        return true;
    }
    let name = comps.last().cloned().unwrap_or_default();
    let ext = Path::new(&name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_string();
    [
        "db", "sqlite", "sqlite3", "mdb", "sql", "pfx", "p12", "key", "pem", "kdbx",
    ]
    .contains(&ext.as_str())
        || name.ends_with("-wal")
        || name.ends_with("-shm")
}

fn identity_key(path: &Path) -> Option<(u64, u64)> {
    std::fs::symlink_metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

pub struct WorktreeInspector<'a> {
    pub catalog: &'a Catalog,
    pub prefs: &'a Preferences,
    pub inventory: &'a ProcessInventory,
    pub now: i64,
    pub manifest_limit: usize,
}

impl<'a> WorktreeInspector<'a> {
    pub fn new(
        catalog: &'a Catalog,
        prefs: &'a Preferences,
        inventory: &'a ProcessInventory,
        now: i64,
        manifest_limit: usize,
    ) -> Self {
        WorktreeInspector {
            catalog,
            prefs,
            inventory,
            now,
            manifest_limit,
        }
    }

    pub fn inspect_repositories(&self, repositories: &[PathBuf], _notices: &mut [Msg]) -> Vec<Finding> {
        let mut out = Vec::new();
        let mut seen_repos: HashSet<(u64, u64)> = HashSet::new();
        let mut seen_trees: HashSet<String> = HashSet::new();
        for repo in repositories {
            if !exists(&repo.join(".git")) || has_symlink_ancestor(repo) {
                continue;
            }
            let common = git(repo, &["rev-parse", "--path-format=absolute", "--git-common-dir"]);
            if !common.ok() {
                continue;
            }
            let common_loc = PathBuf::from(line(&common.text()));
            if has_symlink_ancestor(&common_loc) {
                continue;
            }
            let common_path = canonical(&common_loc);
            let Ok(meta) = std::fs::symlink_metadata(&common_path) else {
                continue;
            };
            if !meta.is_dir() || !seen_repos.insert((meta.dev(), meta.ino())) {
                continue;
            }
            let list = git(repo, &["worktree", "list", "--porcelain", "-z"]);
            if !list.ok() {
                continue;
            }
            let records = parse_records(&list.text());
            let Some(primary) = records.first() else { continue };
            for record in records.iter().skip(1) {
                let key = identity_key(Path::new(&record.path))
                    .map(|(d, i)| format!("{d}:{i}"))
                    .unwrap_or_else(|| record.path.clone());
                if !seen_trees.insert(key) {
                    continue;
                }
                out.push(self.inspect(record, Path::new(&primary.path), &common_path));
            }
        }
        out
    }

    pub fn authorized(&self, repository: &Path, worktree: &Path) -> bool {
        crate::scanner::project_roots(self.prefs)
            .iter()
            .any(|r| contains(r, repository))
            || self.catalog.agent_worktree_roots.iter().any(|r| contains(r, worktree))
    }

    pub fn inspect(&self, record: &Record, repository: &Path, common: &Path) -> Finding {
        let path = PathBuf::from(&record.path);
        let title = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut item = Finding {
            path: record.path.clone(),
            title: Msg::new("title.plain").arg(title),
            category: Category::Worktree,
            rule_id: "git-worktree".into(),
            state: FindingState::Review,
            reason: Msg::new("wt.unverified_generic"),
            logical_bytes: 0,
            allocated_bytes: 0,
            exclusive_bytes: 0,
            shared_links: false,
            partial_measurement: false,
            details: Vec::new(),
            manifest: Manifest::default(),
            worktree: Some(WorktreeAssessment {
                status: WorktreeStatus::Unverified,
                repository: to_string(repository),
                branch: record.branch.clone(),
                head: record.head.clone(),
                comparison_reference: None,
                local_changes: None,
                unpublished_commits: None,
                unmerged_commits: None,
                ignored_paths: None,
                removal_context: None,
            }),
        };
        let preserved = |item: &Finding, status: WorktreeStatus, reason: Msg, state: FindingState| -> Finding {
            let mut r = item.clone();
            r.state = state;
            r.reason = reason;
            r.manifest = Manifest::default();
            if let Some(w) = r.worktree.as_mut() {
                w.status = status;
                w.removal_context = None;
            }
            if let Some(m) = bounded_measurement(&path, 3_000) {
                r.logical_bytes = m.logical_bytes;
                r.allocated_bytes = m.allocated_bytes;
                r.exclusive_bytes = m.exclusive_allocated_bytes;
                r.shared_links = m.hardlinked_files > 0;
                r.partial_measurement = m.partial.is_some();
            }
            r
        };
        use FindingState as S;
        use WorktreeStatus as W;
        let root_meta = std::fs::symlink_metadata(&path);
        let Ok(root_meta) = root_meta
            .as_ref()
            .map_err(|_| ())
            .and_then(|m| if m.is_dir() { Ok(m) } else { Err(()) })
        else {
            return preserved(&item, W::Missing, Msg::new("wt.missing"), S::Review);
        };
        if has_symlink_ancestor(&path) {
            return preserved(&item, W::Missing, Msg::new("wt.missing"), S::Review);
        }
        match path.parent().and_then(|p| std::fs::symlink_metadata(p).ok()) {
            Some(pm) if pm.dev() == root_meta.dev() => {}
            _ => return preserved(&item, W::Unverified, Msg::new("reason.other_volume"), S::Review),
        }
        if let Some(reason) = self
            .catalog
            .protected_reason(&path, &self.prefs.exclusions, Some(repository))
        {
            return preserved(&item, W::Excluded, reason, S::Protected);
        }
        if record.locked {
            return preserved(&item, W::Locked, Msg::new("wt.locked"), S::Protected);
        }
        let usage = self.inventory.reason(&path, &[], None);
        match self.inspect_git(record, &path, repository, common, &mut item, usage.clone()) {
            Ok(Outcome::Ready) => item,
            Ok(Outcome::Preserve(status, reason, state)) => preserved(&item, status, reason, state),
            Err(GitError) => match usage {
                Some(u) => preserved(&item, W::InUse, u, S::InUse),
                None => preserved(&item, W::Unverified, Msg::new("wt.unverified_generic"), S::Review),
            },
        }
    }

    fn inspect_git(
        &self,
        record: &Record,
        path: &Path,
        repository: &Path,
        common: &Path,
        item: &mut Finding,
        usage: Option<Msg>,
    ) -> Result<Outcome, GitError> {
        use FindingState as S;
        use WorktreeStatus as W;
        let admin = administrative_dir(path, repository, common)?;
        let admin_manifest = read_admin(&admin)?;
        if admin_manifest
            .entries
            .iter()
            .any(|e| e.path.ends_with(".lock") || IN_PROGRESS.contains(&e.path.as_str()))
        {
            return Ok(Outcome::Preserve(W::Locked, Msg::new("wt.git_operation"), S::Protected));
        }
        if admin_manifest.entries.iter().any(|e| {
            e.id.kind == EntryKind::Symlink
                || (METADATA_FILES.contains(&e.path.as_str())
                    && METADATA_DIRS.contains(&e.path.as_str()) != (e.id.kind == EntryKind::Dir))
        }) {
            return Ok(Outcome::Preserve(
                W::LocalData,
                Msg::new("wt.local_metadata"),
                S::Protected,
            ));
        }
        // Files Codex and Git add to every worktree are accepted only in
        // their exact known form; anything else (per-worktree refs, other
        // config keys, conflict state) is local data only this worktree holds.
        let mut extra: Vec<&str> = Vec::new();
        for e in &admin_manifest.entries {
            let p = e.path.as_str();
            if METADATA_FILES.contains(&p) {
                continue;
            }
            if e.id.kind == EntryKind::File && known_auxiliary(&admin, p) {
                item.details.push(Msg::new("detail.known_metadata").arg(p));
            } else {
                extra.push(p);
            }
        }
        item.details
            .extend(extra.iter().take(4).map(|p| Msg::new("detail.local_metadata").arg(p)));

        if line(&checked(path, &["rev-parse", "--is-shallow-repository"])?) != "false"
            || exists(&common.join("info/grafts"))
        {
            return Ok(Outcome::Preserve(
                W::Unverified,
                Msg::new("wt.incomplete_history"),
                S::Review,
            ));
        }
        let head = line(&checked(path, &["rev-parse", "--verify", "HEAD"])?);
        if Some(&head) != record.head.as_ref() {
            return Ok(Outcome::Preserve(
                W::Unverified,
                Msg::new("wt.record_changed"),
                S::Review,
            ));
        }
        let sym = git(path, &["symbolic-ref", "--quiet", "HEAD"]);
        let branch = if sym.status == 0 && !sym.timed_out {
            Some(line(&sym.text()))
        } else {
            None
        };
        if branch != record.branch {
            return Ok(Outcome::Preserve(
                W::Unverified,
                Msg::new("wt.record_changed"),
                S::Review,
            ));
        }
        item.details.push(match &branch {
            Some(b) => Msg::new("detail.branch").arg(b.strip_prefix("refs/heads/").unwrap_or(b)),
            None => Msg::new("detail.detached"),
        });

        let status = checked(
            path,
            &[
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--ignore-submodules=none",
            ],
        )?;
        let changes = fields(&status).len() as u64;
        if let Some(w) = item.worktree.as_mut() {
            w.local_changes = Some(changes);
        }
        item.details.push(Msg::new(if changes == 0 {
            "detail.git_clean"
        } else {
            "detail.git_dirty"
        }));
        let ignored = fields(&checked(
            path,
            &[
                "ls-files",
                "--others",
                "--ignored",
                "--exclude-standard",
                "--directory",
                "-z",
            ],
        )?);
        if let Some(w) = item.worktree.as_mut() {
            w.ignored_paths = Some(ignored.len() as u64);
        }
        item.details.push(Msg::new("detail.ignored_count").arg(ignored.len()));
        item.details
            .extend(ignored.iter().take(6).map(|p| Msg::new("detail.ignored").arg(p)));
        let staged = fields(&checked(path, &["ls-files", "--stage", "-z"])?);
        let tracked: HashSet<String> = staged
            .iter()
            .filter_map(|s| s.split_once('\t').map(|(_, p)| p.to_string()))
            .collect();
        if staged.iter().any(|s| s.starts_with("160000 ")) {
            return Ok(Outcome::Preserve(W::LocalData, Msg::new("wt.submodules"), S::Protected));
        }
        let flags = fields(&checked(path, &["ls-files", "-v", "-z"])?);
        if flags.iter().any(|f| !f.starts_with("H ")) {
            return Ok(Outcome::Preserve(
                W::Unverified,
                Msg::new("wt.hidden_changes"),
                S::Review,
            ));
        }
        let mut references: Vec<String> = checked(
            path,
            &["for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"],
        )?
        .lines()
        .map(str::to_string)
        .collect();
        references.sort();
        if references.is_empty() {
            return Ok(Outcome::Preserve(
                W::Unverified,
                Msg::new("wt.no_remote_refs"),
                S::Review,
            ));
        }
        let unpublished = count(path, &[&head, "--not", "--remotes"])?;
        if let Some(w) = item.worktree.as_mut() {
            w.unpublished_commits = Some(unpublished);
        }
        item.details.push(Msg::new("detail.unpublished").arg(unpublished));
        let principal = principal_reference(path, &references);
        let mut integration: Option<(String, String, u64)> = None;
        if let Some(p) = &principal {
            let ph = line(&checked(path, &["rev-parse", "--verify", p])?);
            let range = format!("{p}..{head}");
            let unmerged = count(path, &[&range])?;
            if let Some(w) = item.worktree.as_mut() {
                w.comparison_reference = Some(p.clone());
                w.unmerged_commits = Some(unmerged);
            }
            item.details
                .push(Msg::new("detail.principal").arg(p.strip_prefix("refs/remotes/").unwrap_or(p)));
            item.details.push(Msg::new("detail.unmerged").arg(unmerged));
            integration = Some((p.clone(), ph, unmerged));
        }
        if let Some(u) = usage {
            return Ok(Outcome::Preserve(W::InUse, u, S::InUse));
        }
        if changes > 0 {
            return Ok(Outcome::Preserve(
                W::LocalChanges,
                Msg::new("wt.local_changes"),
                S::Protected,
            ));
        }
        if unpublished > 0 || integration.as_ref().is_some_and(|i| i.2 > 0) {
            return Ok(Outcome::Preserve(
                W::PendingCommits,
                Msg::new("wt.pending_commits"),
                S::Protected,
            ));
        }
        if !extra.is_empty() {
            return Ok(Outcome::Preserve(
                W::LocalData,
                Msg::new("wt.local_metadata"),
                S::Protected,
            ));
        }
        let Some((principal, principal_head, _)) = integration else {
            return Ok(Outcome::Preserve(W::Unverified, Msg::new("wt.no_principal"), S::Review));
        };
        let history = historical_commits(&admin)?;
        if !history.is_empty() {
            let mut args: Vec<&str> = history.iter().map(String::as_str).collect();
            args.extend(["--not", "--remotes"]);
            if count(path, &args)? > 0 {
                return Ok(Outcome::Preserve(
                    W::PendingCommits,
                    Msg::new("wt.reflog_commits"),
                    S::Protected,
                ));
            }
        }
        if exists(&admin.join("COMMIT_EDITMSG")) {
            let saved = bounded_text(&admin.join("COMMIT_EDITMSG"), 1_000_000)?;
            let committed = checked(path, &["log", "-1", "--no-show-signature", "--format=%B", "HEAD"])?;
            if saved.trim_matches('\n') != committed.trim_matches('\n') {
                return Ok(Outcome::Preserve(
                    W::LocalData,
                    Msg::new("wt.local_metadata"),
                    S::Protected,
                ));
            }
        }
        if ignored.iter().any(|p| !regenerable(p, &tracked) || sensitive(p)) {
            return Ok(Outcome::Preserve(
                W::LocalData,
                Msg::new("wt.ignored_state"),
                S::Protected,
            ));
        }
        if !self.authorized(repository, path) {
            return Ok(Outcome::Preserve(
                W::Unverified,
                Msg::new("wt.add_project_root"),
                S::Review,
            ));
        }
        let manifest = build_manifest(
            path,
            &WalkOptions {
                max_entries: self.manifest_limit,
                stop_at_dev_change: true,
            },
        )
        .map_err(|_| GitError)?;
        if manifest.partial.is_some() {
            return Err(GitError);
        }
        let ignored_dirs: Vec<&String> = ignored.iter().filter(|p| p.ends_with('/')).collect();
        for e in &manifest.entries {
            if e.path != ".git" && Path::new(&e.path).file_name().is_some_and(|n| n == ".git") {
                return Ok(Outcome::Preserve(
                    W::LocalData,
                    Msg::new("wt.nested_repository"),
                    S::Protected,
                ));
            }
            if e.id.kind == EntryKind::Other {
                return Ok(Outcome::Preserve(
                    W::LocalData,
                    Msg::new("wt.special_files"),
                    S::Protected,
                ));
            }
            if ignored_dirs.iter().any(|d| e.path.starts_with(d.as_str())) && sensitive(&e.path) {
                return Ok(Outcome::Preserve(
                    W::LocalData,
                    Msg::new("wt.ignored_state"),
                    S::Protected,
                ));
            }
        }
        if let Some(reason) = self.inventory.reason(path, &[], Some(&manifest)) {
            return Ok(Outcome::Preserve(W::InUse, reason, S::InUse));
        }
        let days = self.prefs.retention_days.max(1);
        let cutoff = (self.now - i64::from(days) * 86_400).saturating_mul(1_000_000_000);
        if manifest
            .entries
            .iter()
            .chain(admin_manifest.entries.iter())
            .any(|e| e.id.mtime_ns > cutoff)
        {
            return Ok(Outcome::Preserve(
                W::Recent,
                Msg::new("reason.recent").arg(self.prefs.retention_days),
                S::Protected,
            ));
        }
        if read_admin(&admin)? != admin_manifest {
            return Ok(Outcome::Preserve(
                W::Unverified,
                Msg::new("wt.changed_during_scan"),
                S::Review,
            ));
        }
        item.logical_bytes = manifest.logical_bytes;
        item.allocated_bytes = manifest.allocated_bytes;
        item.exclusive_bytes = manifest.exclusive_allocated_bytes;
        item.shared_links = manifest.hardlinked_files > 0;
        item.manifest = manifest;
        item.state = FindingState::Ready;
        item.reason = Msg::new("wt.ready");
        item.details.push(Msg::new("detail.local_refs_only"));
        item.details.push(Msg::new("detail.no_backup"));
        if let Some(w) = item.worktree.as_mut() {
            w.status = W::Idle;
            w.removal_context = Some(WorktreeRemovalContext {
                repository: to_string(repository),
                common_directory: to_string(common),
                administrative_directory: to_string(&admin),
                head,
                branch,
                integration_reference: principal,
                integration_head: principal_head,
                remote_references: references,
                administrative_manifest: admin_manifest,
            });
        }
        Ok(Outcome::Ready)
    }

    /// Whether a finding still describes a worktree this module produced.
    pub fn recognizes(&self, f: &Finding) -> bool {
        let Some(w) = &f.worktree else { return false };
        let Some(ctx) = &w.removal_context else { return false };
        let admin = Path::new(&ctx.administrative_directory);
        f.rule_id == "git-worktree"
            && f.category == Category::Worktree
            && w.status == WorktreeStatus::Idle
            && f.path != ctx.repository
            && self.authorized(Path::new(&ctx.repository), Path::new(&f.path))
            && admin.parent() == Some(Path::new(&ctx.common_directory).join("worktrees").as_path())
            && !ctx.administrative_manifest.entries.is_empty()
            && !has_symlink_ancestor(Path::new(&f.path))
            && !has_symlink_ancestor(admin)
    }

    /// Re-runs every Git and file check (process usage is checked by the
    /// executor) and requires the same context and manifest as the plan.
    pub fn revalidate(&self, f: &Finding) -> Result<(), Msg> {
        let changed = || Msg::new("wt.changed_since_plan");
        if !self.recognizes(f) {
            return Err(Msg::new("wt.not_recognized"));
        }
        let ctx = f
            .worktree
            .as_ref()
            .and_then(|w| w.removal_context.as_ref())
            .ok_or_else(changed)?;
        let list =
            checked(Path::new(&ctx.repository), &["worktree", "list", "--porcelain", "-z"]).map_err(|_| changed())?;
        let records = parse_records(&list);
        if records.first().map(|r| r.path.as_str()) != Some(ctx.repository.as_str()) {
            return Err(Msg::new("wt.record_changed"));
        }
        let Some(record) = records.iter().skip(1).find(|r| r.path == f.path) else {
            return Err(Msg::new("wt.record_changed"));
        };
        let empty = ProcessInventory::empty_complete();
        let fresh = WorktreeInspector {
            inventory: &empty,
            now: crate::store::now_secs(),
            ..*self
        };
        let current = fresh.inspect(record, Path::new(&ctx.repository), Path::new(&ctx.common_directory));
        let same_ctx = current.worktree.as_ref().and_then(|w| w.removal_context.as_ref()) == Some(ctx);
        if current.state != FindingState::Ready || !same_ctx || current.manifest != f.manifest {
            return Err(changed());
        }
        Ok(())
    }
}

enum Outcome {
    Ready,
    Preserve(WorktreeStatus, Msg, FindingState),
}

fn read_admin(admin: &Path) -> Result<Manifest, GitError> {
    let m = build_manifest(
        admin,
        &WalkOptions {
            max_entries: ADMIN_LIMIT,
            stop_at_dev_change: true,
        },
    )
    .map_err(|_| GitError)?;
    if m.partial.is_some() {
        return Err(GitError);
    }
    Ok(m)
}

/// Verifies the link between the worktree's `.git` file, its administrative
/// directory and the shared repository, and returns the administrative path.
fn administrative_dir(path: &Path, repository: &Path, common: &Path) -> Result<PathBuf, GitError> {
    if path == repository || has_symlink_ancestor(common) || has_symlink_ancestor(&repository.join(".git")) {
        return Err(GitError);
    }
    let marker = bounded_text(&path.join(".git"), 8192)?;
    let value = line(&marker);
    let value = value.strip_prefix("gitdir: ").ok_or(GitError)?;
    let loc = if value.starts_with('/') {
        PathBuf::from(value)
    } else {
        path.join(value)
    };
    if has_symlink_ancestor(&loc) || crate::paths::is_symlink(&loc) {
        return Err(GitError);
    }
    let admin = canonical(&loc);
    if admin.parent() != Some(common.join("worktrees").as_path()) || has_symlink_ancestor(&admin) {
        return Err(GitError);
    }
    if canonical(Path::new(&line(&checked(
        path,
        &["rev-parse", "--path-format=absolute", "--git-dir"],
    )?)))
        != admin
    {
        return Err(GitError);
    }
    if canonical(Path::new(&line(&checked(
        path,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?)))
        != common
    {
        return Err(GitError);
    }
    if canonical(Path::new(&line(&bounded_text(&admin.join("gitdir"), 8192)?))) != path.join(".git") {
        return Err(GitError);
    }
    Ok(admin)
}

/// Auxiliary administrative files with a verified, harmless form:
/// - `codex-thread.json`: Codex's owner marker, only `version` and
///   `ownerThreadId` scalars;
/// - `config.worktree`: only Codex's `[codex] localEnvironmentConfigPath`;
/// - `MERGE_RR`: empty (no rerere conflict in progress);
/// - `FETCH_HEAD`: empty, or only fetched object IDs from a remote.
pub fn known_auxiliary(admin: &Path, name: &str) -> bool {
    let read = |limit| bounded_text(&admin.join(name), limit).ok();
    match name {
        "codex-thread.json" => read(4096)
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
            .and_then(|v| v.as_object().cloned())
            .is_some_and(|o| {
                !o.is_empty()
                    && o.iter()
                        .all(|(k, v)| (k == "version" || k == "ownerThreadId") && (v.is_string() || v.is_number()))
            }),
        "config.worktree" => read(4096).is_some_and(|t| {
            let mut section = String::new();
            t.lines()
                .map(str::trim)
                .filter(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with(';'))
                .all(|l| {
                    if l.starts_with('[') {
                        section = l.to_ascii_lowercase();
                        return section == "[codex]";
                    }
                    let key = l.split('=').next().unwrap_or("").trim().to_ascii_lowercase();
                    section == "[codex]" && key == "localenvironmentconfigpath"
                })
        }),
        "MERGE_RR" => read(0).is_some_and(|t| t.is_empty()),
        "FETCH_HEAD" => read(256 * 1024).is_some_and(|t| {
            t.lines().all(|l| {
                let mut parts = l.splitn(3, '\t');
                let oid = parts.next().unwrap_or("");
                let flag = parts.next();
                (oid.len() == 40 || oid.len() == 64)
                    && oid.chars().all(|c| c.is_ascii_hexdigit())
                    && matches!(flag, Some("") | Some("not-for-merge"))
            })
        }),
        _ => false,
    }
}

fn principal_reference(path: &Path, references: &[String]) -> Option<String> {
    let preferred = ["refs/remotes/upstream/HEAD", "refs/remotes/origin/HEAD"];
    let others: Vec<&str> = references
        .iter()
        .filter_map(|r| r.split(' ').next())
        .filter(|r| r.ends_with("/HEAD") && !preferred.contains(r))
        .collect();
    let mut candidates: Vec<&str> = preferred.to_vec();
    if others.len() == 1 {
        candidates.push(others[0]);
    }
    for c in candidates {
        let r = git(path, &["symbolic-ref", "--quiet", c]);
        let v = line(&r.text());
        if r.status == 0 && !r.timed_out && v.starts_with("refs/remotes/") && v != c {
            return Some(v);
        }
    }
    None
}

fn historical_commits(admin: &Path) -> Result<Vec<String>, GitError> {
    let mut commits: BTreeSet<String> = BTreeSet::new();
    for (name, n) in [("ORIG_HEAD", 1usize), ("logs/HEAD", 2usize)] {
        let p = admin.join(name);
        if !exists(&p) {
            continue;
        }
        let text = bounded_text(&p, 1_000_000)?;
        for row in text.lines() {
            for field in row.split(' ').take(n) {
                if !(field.len() == 40 || field.len() == 64) || !field.chars().all(|c| c.is_ascii_hexdigit()) {
                    return Err(GitError);
                }
                if field.chars().any(|c| c != '0') {
                    commits.insert(field.to_string());
                }
            }
        }
    }
    if commits.len() > 1_000 {
        return Err(GitError);
    }
    Ok(commits.into_iter().collect())
}

/// Quick, bounded size for preserved worktrees: never authorizes removal.
pub fn bounded_measurement(path: &Path, limit: usize) -> Option<Manifest> {
    build_manifest(
        path,
        &WalkOptions {
            max_entries: limit,
            stop_at_dev_change: true,
        },
    )
    .ok()
}

#[derive(Debug)]
pub enum WorktreeRemovalError {
    /// Nothing was removed.
    Kept(Msg),
    /// Some files were removed.
    Partial(Msg, RemovalReport),
}

/// Removes a validated worktree directory, `.git` last, then its single
/// administrative directory. Never runs `git worktree remove`, `--force`,
/// prune or branch deletion. On a failure inside the worktree, the `.git`
/// marker is restored so Git still recognizes what is left.
pub fn remove_worktree(f: &Finding, hook: &mut dyn FnMut(&str)) -> Result<RemovalReport, WorktreeRemovalError> {
    let Some(ctx) = f.worktree.as_ref().and_then(|w| w.removal_context.as_ref()) else {
        return Err(WorktreeRemovalError::Kept(Msg::new("wt.not_recognized")));
    };
    let admin = Path::new(&ctx.administrative_directory);
    if read_admin(admin).ok().as_ref() != Some(&ctx.administrative_manifest) {
        return Err(WorktreeRemovalError::Kept(Msg::new("wt.record_changed")));
    }
    let report = fsx::remove_manifest_with_hook(Path::new(&f.path), &f.manifest, Some(".git"), hook);
    if !report.complete {
        restore_marker(f, &ctx.administrative_directory);
        let reason = stop_msg(report.stopped.as_ref());
        if report.removed_entries == 0 {
            return Err(WorktreeRemovalError::Kept(reason));
        }
        return Err(WorktreeRemovalError::Partial(reason, report));
    }
    if read_admin(admin).ok().as_ref() != Some(&ctx.administrative_manifest) {
        return Err(WorktreeRemovalError::Partial(Msg::new("wt.admin_needs_review"), report));
    }
    let admin_report = fsx::remove_manifest(admin, &ctx.administrative_manifest, None);
    if !admin_report.complete {
        return Err(WorktreeRemovalError::Partial(Msg::new("wt.admin_needs_review"), report));
    }
    Ok(report)
}

fn restore_marker(f: &Finding, admin: &str) {
    use rustix::fs::{openat, Mode, OFlags};
    let Some(root) = f.manifest.root() else { return };
    let Ok(fd) = fsx::open_dir_nofollow(Path::new(&f.path)) else {
        return;
    };
    let Ok(st) = rustix::fs::fstat(&fd) else { return };
    if st.st_dev != root.id.dev || st.st_ino != root.id.ino {
        return;
    }
    let Ok(marker) = openat(
        &fd,
        ".git",
        OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(0o600),
    ) else {
        return;
    };
    let mut file = std::fs::File::from(marker);
    let _ = std::io::Write::write_all(&mut file, format!("gitdir: {admin}\n").as_bytes());
    let _ = file.sync_all();
}

pub fn stop_msg(stop: Option<&RemovalStop>) -> Msg {
    match stop {
        None => Msg::new("removal.unknown"),
        Some(RemovalStop::Unreachable { .. }) => Msg::new("removal.unreachable"),
        Some(RemovalStop::NewEntry { path }) => Msg::new("removal.new_entry").arg(path),
        Some(RemovalStop::Changed { path }) => Msg::new("removal.changed").arg(path),
        Some(RemovalStop::Missing { path }) => Msg::new("removal.missing").arg(path),
        Some(RemovalStop::PartialManifest) => Msg::new("reason.partial_limit"),
        Some(RemovalStop::Failed { path, errno }) => Msg::new("removal.failed").arg(path).arg(errno),
    }
}
