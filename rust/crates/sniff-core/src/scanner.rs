//! Analysis: applies the catalog to the filesystem and classifies each
//! candidate. Never removes anything.

use crate::catalog::{Catalog, Layout, Rule, BUILD_TOKENS};
use crate::fsx::{self, build_manifest, Manifest, OpenError, PartialReason, WalkOptions};
use crate::model::*;
use crate::paths::{canonical, contains, has_symlink_ancestor, to_string};
use crate::procs::ProcessInventory;
use crate::worktree::WorktreeInspector;
use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const MANIFEST_LIMIT: usize = 180_000;
pub const LOG_WALK_LIMIT: usize = 15_000;
pub const DISCOVERY_LIMIT: usize = 7_000;
pub const DISCOVERY_DEPTH: usize = 5;
pub const NPX_LOCK_LIMIT: u64 = 8_000_000;

pub struct Scanner<'a> {
    pub catalog: &'a Catalog,
    pub prefs: &'a Preferences,
    pub inventory: &'a ProcessInventory,
    pub now: i64,
    pub manifest_limit: usize,
    /// Reports progress (localized by the caller).
    pub progress: &'a dyn Fn(Msg),
}

pub fn project_roots(prefs: &Preferences) -> Vec<PathBuf> {
    prefs.project_roots.iter().map(|r| canonical(Path::new(r))).collect()
}

impl<'a> Scanner<'a> {
    pub fn new(
        catalog: &'a Catalog,
        prefs: &'a Preferences,
        inventory: &'a ProcessInventory,
        progress: &'a dyn Fn(Msg),
    ) -> Self {
        Scanner {
            catalog,
            prefs,
            inventory,
            now: crate::store::now_secs(),
            manifest_limit: MANIFEST_LIMIT,
            progress,
        }
    }

    pub fn scan(&self, mode: ScanMode) -> ScanSnapshot {
        let mut findings = Vec::new();
        let mut notices = Vec::new();
        if mode != ScanMode::Worktrees {
            for rule in &self.catalog.rules {
                (self.progress)(Msg::new("progress.sniffing").nested(Msg::new(&rule.category.title_key())));
                self.scan_rule(rule, &mut findings, &mut notices);
            }
        }
        if mode != ScanMode::Quick {
            (self.progress)(Msg::new("progress.projects"));
            let repos = self.discover_projects(&mut notices, mode == ScanMode::Full, &mut findings);
            (self.progress)(Msg::new("progress.worktrees"));
            let inspector =
                WorktreeInspector::new(self.catalog, self.prefs, self.inventory, self.now, self.manifest_limit);
            findings.extend(inspector.inspect_repositories(&repos, &mut notices));
            if mode == ScanMode::Full {
                (self.progress)(Msg::new("progress.docker"));
                findings.extend(inspect_docker());
            }
        }
        if mode == ScanMode::Worktrees {
            notices.push(Msg::new("notice.worktrees_only"));
        }
        findings.sort_by(|a, b| {
            (a.state != FindingState::Ready)
                .cmp(&(b.state != FindingState::Ready))
                .then(b.allocated_bytes.cmp(&a.allocated_bytes))
        });
        notices.push(Msg::new("notice.allocation_estimate"));
        notices.push(Msg::new("notice.visible_processes"));
        if !self.inventory.is_complete() {
            notices.push(Msg::new("notice.process_inventory_incomplete"));
        }
        ScanSnapshot {
            date: self.now,
            home: to_string(&self.catalog.home),
            mode,
            findings,
            notices,
        }
    }

    fn scan_rule(&self, rule: &Rule, out: &mut Vec<Finding>, notices: &mut Vec<Msg>) {
        let base = &rule.base;
        match std::fs::symlink_metadata(base) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                notices.push(Msg::new("notice.no_access").arg(to_string(base)));
                return;
            }
            Err(_) => return,
            Ok(m) if m.file_type().is_symlink() || has_symlink_ancestor(base) => {
                out.push(self.protected_symlink(rule, base));
                return;
            }
            Ok(_) => {}
        }
        match &rule.layout {
            Layout::Whole => out.push(self.inspect(base, rule, Msg::new(&rule.category.title_key()))),
            Layout::Children(prefix) => {
                let entries = match std::fs::read_dir(base) {
                    Ok(it) => it,
                    Err(e) => {
                        out.push(self.inaccessible(base, rule, Msg::new("reason.io_error").arg(e)));
                        return;
                    }
                };
                let mut names: Vec<_> = entries
                    .flatten()
                    .filter_map(|e| e.file_name().into_string().ok())
                    .filter(|n| n.starts_with(prefix))
                    .collect();
                names.sort();
                for n in names {
                    let p = base.join(&n);
                    out.push(self.inspect(&p, rule, Msg::new("title.plain").arg(&n)));
                }
            }
            Layout::Logs { .. } => {
                let m = match build_manifest(
                    base,
                    &WalkOptions {
                        max_entries: LOG_WALK_LIMIT,
                        stop_at_dev_change: true,
                    },
                ) {
                    Ok(m) => m,
                    Err(e) => {
                        out.push(self.inaccessible(base, rule, open_error_msg(&e)));
                        return;
                    }
                };
                if m.partial.is_some() {
                    notices.push(Msg::new("notice.logs_partial").arg(to_string(base)));
                }
                // Logs still inside the retention period are summarized in
                // one row per rule: they cannot be selected, and listing each file only
                // adds noise. Everything else stays one item per file.
                let mut recent: std::collections::BTreeMap<PathBuf, (u64, u64, u64)> = Default::default();
                for e in &m.entries {
                    if e.id.kind != fsx::EntryKind::File {
                        continue;
                    }
                    let p = base.join(&e.path);
                    if rule.matches(&p) {
                        let name = p
                            .file_name()
                            .map(|n| n.to_string_lossy().into_owned())
                            .unwrap_or_default();
                        let f = self.inspect_file(&p, rule, Msg::new("title.plain").arg(name));
                        if f.state == FindingState::Protected && f.reason.k == "reason.recent" {
                            let g = recent.entry(base.to_path_buf()).or_default();
                            g.0 += 1;
                            g.1 += f.logical_bytes;
                            g.2 += f.allocated_bytes;
                        } else {
                            out.push(f);
                        }
                    }
                }
                for (dir, (count, logical, allocated)) in recent {
                    let mut f =
                        self.base_finding(&dir, rule.id, rule.category, Msg::new("title.recent_logs").arg(count));
                    f.rule_id = format!("{}-recent", rule.id);
                    f.state = FindingState::Protected;
                    f.reason = Msg::new("reason.recent").arg(self.prefs.log_retention_days);
                    f.logical_bytes = logical;
                    f.allocated_bytes = allocated;
                    f.exclusive_bytes = allocated;
                    out.push(f);
                }
            }
        }
    }

    fn base_finding(&self, path: &Path, rule_id: &str, category: Category, title: Msg) -> Finding {
        Finding {
            path: to_string(path),
            title,
            category,
            rule_id: rule_id.to_string(),
            state: FindingState::Ready,
            reason: Msg::new("reason.rule_ready"),
            logical_bytes: 0,
            allocated_bytes: 0,
            exclusive_bytes: 0,
            shared_links: false,
            partial_measurement: false,
            details: Vec::new(),
            manifest: Manifest::default(),
            worktree: None,
        }
    }

    fn protected_symlink(&self, rule: &Rule, path: &Path) -> Finding {
        let mut f = self.base_finding(path, rule.id, rule.category, Msg::new(&rule.category.title_key()));
        f.state = FindingState::Protected;
        f.reason = Msg::new("reason.symlink_path");
        f
    }

    fn inaccessible(&self, path: &Path, rule: &Rule, reason: Msg) -> Finding {
        let mut f = self.base_finding(path, rule.id, rule.category, Msg::new(&rule.category.title_key()));
        f.state = FindingState::Inaccessible;
        f.reason = reason;
        f
    }

    /// Classifies one directory candidate of a rule.
    pub fn inspect(&self, path: &Path, rule: &Rule, title: Msg) -> Finding {
        self.inspect_with(path, rule.id, rule.category, rule.tokens, title)
    }

    fn inspect_file(&self, path: &Path, rule: &Rule, title: Msg) -> Finding {
        self.inspect_with(path, rule.id, rule.category, rule.tokens, title)
    }

    pub fn inspect_with(&self, path: &Path, rule_id: &str, category: Category, tokens: &[&str], title: Msg) -> Finding {
        let mut f = self.base_finding(path, rule_id, category, title);
        let protected = self.catalog.protected_reason(path, &self.prefs.exclusions, None);
        let manifest = match measure(path, self.manifest_limit) {
            Ok(m) => m,
            Err(e) => {
                f.state = FindingState::Inaccessible;
                f.reason = open_error_msg(&e);
                return f;
            }
        };
        f.logical_bytes = manifest.logical_bytes;
        f.allocated_bytes = manifest.allocated_bytes;
        f.exclusive_bytes = manifest.exclusive_allocated_bytes;
        f.shared_links = manifest.hardlinked_files > 0;
        if manifest.externally_linked_files > 0 {
            f.details
                .push(Msg::new("detail.external_links").arg(manifest.externally_linked_files));
        }
        if let Some(reason) = protected {
            f.state = FindingState::Protected;
            f.reason = reason;
            f.partial_measurement = manifest.partial.is_some();
            return f;
        }
        if let Some(p) = manifest.partial {
            f.partial_measurement = true;
            f.state = if p == PartialReason::PermissionDenied {
                FindingState::Inaccessible
            } else {
                FindingState::Review
            };
            f.reason = partial_msg(p);
            return f;
        }
        if let Some(reason) = self.inventory.reason(path, tokens, Some(&manifest)) {
            f.state = FindingState::InUse;
            f.reason = reason;
            return f;
        }
        if let Some(reason) = retention_reason(category, &manifest, self.prefs, self.now) {
            f.state = FindingState::Protected;
            f.reason = reason;
            return f;
        }
        if category == Category::Npx && npx_must_preserve(path) {
            f.state = FindingState::Protected;
            f.reason = Msg::new("reason.npx_mcp");
            return f;
        }
        if category == Category::Logs {
            f.reason = Msg::new("reason.logs_manual");
        }
        f.manifest = manifest;
        f
    }

    /// Breadth-first discovery of repositories under the configured project
    /// roots and the agents' worktree folders. Adds build findings when
    /// `with_builds` and returns repositories that have a `.git` entry.
    fn discover_projects(&self, notices: &mut Vec<Msg>, with_builds: bool, out: &mut Vec<Finding>) -> Vec<PathBuf> {
        let roots = project_roots(self.prefs);
        let mut starts: Vec<PathBuf> = roots.clone();
        starts.extend(self.catalog.agent_worktree_roots.iter().cloned());
        let mut queue: VecDeque<(PathBuf, usize)> = starts.into_iter().map(|p| (p, 0)).collect();
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut repos = Vec::new();
        let mut visited = 0usize;
        const SKIP: &[&str] = &[
            "node_modules",
            "target",
            ".build",
            ".git",
            "vendor",
            ".venv",
            "venv",
            "dist",
            "build",
            ".cache",
        ];
        while let Some((dir, depth)) = queue.pop_front() {
            if !seen.insert(dir.clone()) {
                continue;
            }
            if visited >= DISCOVERY_LIMIT {
                notices.push(Msg::new("notice.discovery_limited"));
                break;
            }
            visited += 1;
            match std::fs::symlink_metadata(&dir) {
                Ok(m) if m.is_dir() => {}
                _ => continue,
            }
            if has_symlink_ancestor(&dir) {
                continue;
            }
            let has = |n: &str| std::fs::symlink_metadata(dir.join(n)).is_ok();
            let is_git = has(".git");
            if is_git {
                repos.push(dir.clone());
            }
            if with_builds && roots.iter().any(|r| contains(r, &dir)) {
                if has("Cargo.toml") && std::fs::symlink_metadata(dir.join("target")).is_ok_and(|m| m.is_dir()) {
                    let name = dir
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    out.push(self.inspect_with(
                        &dir.join("target"),
                        "rust-target",
                        Category::Build,
                        BUILD_TOKENS,
                        Msg::new("title.build").arg(name).arg("target"),
                    ));
                }
                if has("Package.swift") && std::fs::symlink_metadata(dir.join(".build")).is_ok_and(|m| m.is_dir()) {
                    let name = dir
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    out.push(self.inspect_with(
                        &dir.join(".build"),
                        "swift-build",
                        Category::Build,
                        BUILD_TOKENS,
                        Msg::new("title.build").arg(name).arg(".build"),
                    ));
                }
            }
            if is_git || depth >= DISCOVERY_DEPTH {
                continue;
            }
            let entries = match std::fs::read_dir(&dir) {
                Ok(e) => e,
                Err(_) => {
                    notices.push(Msg::new("notice.project_no_access").arg(to_string(&dir)));
                    continue;
                }
            };
            let mut children: Vec<PathBuf> = entries
                .flatten()
                .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                .filter_map(|e| {
                    let n = e.file_name().into_string().ok()?;
                    if SKIP.contains(&n.as_str()) || (n.starts_with('.') && n != ".claude" && n != ".codex") {
                        return None;
                    }
                    Some(e.path())
                })
                .collect();
            children.sort();
            queue.extend(children.into_iter().map(|c| (c, depth + 1)));
        }
        repos
    }
}

/// Measures a candidate. A regular file (log) gets a one-entry manifest.
pub fn measure(path: &Path, limit: usize) -> Result<Manifest, OpenError> {
    let st = fsx::lstat_nofollow(path)?;
    if fsx::EntryKind::from_stat(&st) == fsx::EntryKind::Dir {
        build_manifest(
            path,
            &WalkOptions {
                max_entries: limit,
                stop_at_dev_change: true,
            },
        )
    } else {
        let id = fsx::Identity::from_stat(&st);
        let allocated = (st.st_blocks as u64).saturating_mul(512);
        let mount_id = fsx::open_parent_nofollow(path)
            .ok()
            .and_then(|(parent, name)| fsx::mount_id(&parent, name.as_c_str()));
        Ok(Manifest {
            exclusive_allocated_bytes: if id.nlink > 1 { 0 } else { allocated },
            mount_id,
            logical_bytes: if id.kind == fsx::EntryKind::File { id.size } else { 0 },
            allocated_bytes: allocated,
            hardlinked_files: u64::from(id.nlink > 1),
            externally_linked_files: u64::from(id.nlink > 1),
            newest_mtime_ns: id.mtime_ns,
            entries: vec![fsx::ManifestEntry {
                path: String::new(),
                id,
                allocated,
            }],
            partial: None,
        })
    }
}

pub fn open_error_msg(e: &OpenError) -> Msg {
    match e {
        OpenError::SymlinkAncestor(_) | OpenError::NotAbsolute => Msg::new("reason.symlink_path"),
        OpenError::Denied => Msg::new("reason.no_access"),
        OpenError::NotFound => Msg::new("reason.missing"),
        OpenError::Other(err) => Msg::new("reason.io_error").arg(err),
    }
}

pub fn partial_msg(p: PartialReason) -> Msg {
    match p {
        PartialReason::EntryLimit | PartialReason::DepthLimit => Msg::new("reason.partial_limit"),
        PartialReason::CrossesFilesystem => Msg::new("reason.other_volume"),
        PartialReason::PermissionDenied => Msg::new("reason.no_access"),
        PartialReason::NonUtf8Name => Msg::new("reason.non_utf8"),
        PartialReason::ReadError | PartialReason::Changed => Msg::new("reason.changed_during_scan"),
    }
}

/// Retention for categories whose items are judged by age.
pub fn retention_reason(category: Category, m: &Manifest, prefs: &Preferences, now: i64) -> Option<Msg> {
    let days = match category {
        Category::Logs => prefs.log_retention_days,
        Category::Npx | Category::RuntimeInstalls => prefs.retention_days,
        _ => return None,
    };
    let cutoff = (now - i64::from(days.max(1)) * 86_400).saturating_mul(1_000_000_000);
    if m.entries.iter().any(|e| e.id.mtime_ns > cutoff) {
        Some(Msg::new("reason.recent").arg(days))
    } else {
        None
    }
}

/// npx environments that reference MCP, or whose lockfile cannot be read
/// safely, are preserved.
pub fn npx_must_preserve(dir: &Path) -> bool {
    use rustix::fs::{openat, Mode, OFlags};
    let Ok(dfd) = fsx::open_dir_nofollow(dir) else {
        return true;
    };
    let Ok(fd) = openat(
        &dfd,
        "package-lock.json",
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) else {
        return true;
    };
    let Ok(st) = rustix::fs::fstat(&fd) else { return true };
    if fsx::EntryKind::from_stat(&st) != fsx::EntryKind::File || st.st_size < 0 || st.st_size as u64 >= NPX_LOCK_LIMIT {
        return true;
    }
    let mut file = std::fs::File::from(fd);
    let mut buf = Vec::new();
    if std::io::Read::read_to_end(&mut file, &mut buf).is_err() {
        return true;
    }
    let Ok(text) = String::from_utf8(buf) else { return true };
    let lower = text.to_lowercase();
    lower.contains("mcp") || lower.contains("@modelcontextprotocol")
}

/// Docker storage is inspected only when the engine is already running.
/// With socket activation, calling the client would start the engine, so the
/// service state is read from systemd first.
pub fn inspect_docker() -> Vec<Finding> {
    let docker = Path::new("/usr/bin/docker");
    if !docker.exists() {
        return Vec::new();
    }
    let mk = |reason: Msg, path: &str, title: Msg| Finding {
        path: path.to_string(),
        title,
        category: Category::Docker,
        rule_id: "docker-inspect".into(),
        state: FindingState::Review,
        reason,
        logical_bytes: 0,
        allocated_bytes: 0,
        exclusive_bytes: 0,
        shared_links: false,
        partial_measurement: true,
        details: vec![Msg::new("detail.docker_inspect_only")],
        manifest: Manifest::default(),
        worktree: None,
    };
    let systemctl = Path::new("/usr/bin/systemctl");
    let active = crate::command::run(
        systemctl,
        &["is-active", "--quiet", "docker.service"],
        None,
        Duration::from_secs(5),
    );
    if !active.ok() {
        return vec![mk(
            Msg::new("reason.docker_not_running"),
            "docker://engine",
            Msg::new("category.docker"),
        )];
    }
    let df = crate::command::run(
        docker,
        &["system", "df", "--format", "{{json .}}"],
        None,
        Duration::from_secs(15),
    );
    if !df.ok() {
        return vec![mk(
            Msg::new("reason.docker_unavailable"),
            "docker://engine",
            Msg::new("category.docker"),
        )];
    }
    let mut out = Vec::new();
    for line in df.text().lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let kind = v.get("Type").and_then(|x| x.as_str()).unwrap_or("?").to_string();
        let mut f = mk(
            Msg::new("reason.docker_preserved"),
            &format!("docker://{kind}"),
            Msg::new("title.plain").arg(&kind),
        );
        f.details.insert(
            0,
            Msg::new("detail.docker_df")
                .arg(v.get("Size").and_then(|x| x.as_str()).unwrap_or("?"))
                .arg(v.get("Reclaimable").and_then(|x| x.as_str()).unwrap_or("?"))
                .arg(
                    v.get("Active")
                        .map(|x| x.to_string().trim_matches('"').to_string())
                        .unwrap_or_default(),
                ),
        );
        out.push(f);
    }
    out
}
