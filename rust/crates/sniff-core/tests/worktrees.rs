mod common;

use common::*;
use sniff_core::model::*;
use sniff_core::procs::ProcessInventory;
use std::fs;
use std::path::{Path, PathBuf};

struct Repo {
    fx: Fixture,
    main: PathBuf,
    tree: PathBuf,
}

/// Primary checkout at `projects/main` on `trunk-real`, with `origin/HEAD`
/// recorded as a symref to `origin/trunk-real`, and a linked worktree outside
/// the projects folder on branch `fixture-idle`. Everything is 60 days old.
fn repo(name: &str) -> Repo {
    let mut fx = Fixture::new(name);
    let main = fx.home.join("projects/main");
    fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "-q", "-b", "trunk-real"]);
    fs::write(
        main.join(".gitignore"),
        "local.db\n.env\n.claude/\nnode_modules/\nscratch/\nbin/\nobj/\ntarget/\n",
    )
    .unwrap();
    fs::write(main.join("package.json"), "{}").unwrap();
    fs::write(main.join("README.md"), "hello").unwrap();
    git(&main, &["add", "."]);
    git(&main, &["commit", "-q", "-m", "initial"]);
    let head = git(&main, &["rev-parse", "HEAD"]);
    git(&main, &["update-ref", "refs/remotes/origin/trunk-real", &head]);
    git(
        &main,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/trunk-real",
        ],
    );
    let tree = fx.home.join("outside/idle $(literal) árvore");
    fs::create_dir_all(tree.parent().unwrap()).unwrap();
    git(
        &main,
        &["worktree", "add", "-q", "-b", "fixture-idle", tree.to_str().unwrap()],
    );
    fx.prefs
        .project_roots
        .push(fx.home.join("projects").to_string_lossy().into_owned());
    let r = Repo { fx, main, tree };
    r.age();
    r
}

impl Repo {
    fn age(&self) {
        age(&self.tree, 60);
        age(&self.main.join(".git/worktrees"), 60);
    }
    fn scan(&self) -> ScanSnapshot {
        self.fx
            .scan_with(&ProcessInventory::empty_complete(), ScanMode::Worktrees)
    }
    fn item(&self) -> Finding {
        self.fx.finding(&self.scan(), &self.tree)
    }
    fn status(&self) -> WorktreeStatus {
        self.item().worktree.unwrap().status
    }
}

#[test]
fn idle_published_worktree_requires_explicit_manual_cleanup() {
    let mut r = repo("idle");
    let main_head = git(&r.main, &["rev-parse", "HEAD"]);
    let f = r.item();
    assert_eq!(f.state, FindingState::Ready, "{:?} {:?}", f.reason, f.details);
    let w = f.worktree.as_ref().unwrap();
    assert_eq!(w.status, WorktreeStatus::Idle);
    assert_eq!(
        w.comparison_reference.as_deref(),
        Some("refs/remotes/origin/trunk-real")
    );
    assert!(f.details.iter().any(|d| d.k == "detail.no_backup"));
    // Disabled by default.
    let report = r.fx.clean(&[f.clone()], store_now());
    assert_eq!(report.outcomes[0].message.k, "exec.category_not_allowed");
    // Never automatic, even when enabled.
    r.fx.prefs.enabled_categories.insert(Category::Worktree);
    let report =
        r.fx.clean_with(&[f.clone()], store_now(), true, &mut |_| None, &mut |_| {});
    assert_eq!(report.outcomes[0].message.k, "exec.category_not_allowed");
    // Unfiltered default plans never select worktrees.
    let scan = r.scan();
    assert!(sniff_core::plan::select(Some(&scan), &r.fx.prefs, &[], &[], &r.fx.home, scan.date).is_err());
    let items = sniff_core::plan::select(
        Some(&scan),
        &r.fx.prefs,
        &[Category::Worktree],
        &[],
        &r.fx.home,
        scan.date,
    )
    .unwrap();
    let report = r.fx.clean(&items, scan.date);
    assert!(removed(&report, &r.tree), "{:?}", report.outcomes);
    assert!(!r.tree.exists());
    let admin = r.main.join(".git/worktrees");
    assert!(fs::read_dir(&admin).map(|d| d.count() == 0).unwrap_or(true));
    // Primary checkout and branch are untouched.
    assert_eq!(git(&r.main, &["rev-parse", "HEAD"]), main_head);
    assert!(!git(&r.main, &["rev-parse", "--verify", "refs/heads/fixture-idle"]).is_empty());
    assert!(!git(&r.main, &["worktree", "list", "--porcelain"]).contains("árvore"));
}

fn store_now() -> i64 {
    sniff_core::store::now_secs()
}

#[test]
fn local_changes_are_preserved() {
    for kind in ["unstaged", "staged", "untracked"] {
        let r = repo(&format!("changes-{kind}"));
        match kind {
            "unstaged" => fs::write(r.tree.join("README.md"), "edited").unwrap(),
            "staged" => {
                fs::write(r.tree.join("README.md"), "edited").unwrap();
                git(&r.tree, &["add", "README.md"]);
            }
            _ => fs::write(r.tree.join("new.txt"), "new").unwrap(),
        }
        r.age();
        assert_eq!(r.status(), WorktreeStatus::LocalChanges, "{kind}");
    }
}

#[test]
fn unpublished_and_unmerged_commits_are_preserved() {
    for published in [false, true] {
        let r = repo(&format!("commits-{published}"));
        fs::write(r.tree.join("feature.txt"), "f").unwrap();
        git(&r.tree, &["add", "."]);
        git(&r.tree, &["commit", "-q", "-m", "feature"]);
        if published {
            let h = git(&r.tree, &["rev-parse", "HEAD"]);
            git(&r.main, &["update-ref", "refs/remotes/origin/fixture-idle", &h]);
        }
        r.age();
        let f = r.item();
        let w = f.worktree.unwrap();
        assert_eq!(w.status, WorktreeStatus::PendingCommits);
        assert_eq!(w.unpublished_commits, Some(if published { 0 } else { 1 }));
        assert_eq!(w.unmerged_commits, Some(1));
    }
}

#[test]
fn reflog_keeps_earlier_unpublished_commits() {
    let r = repo("reflog");
    git(&r.tree, &["checkout", "-q", "--detach"]);
    fs::write(r.tree.join("lost.txt"), "work").unwrap();
    git(&r.tree, &["add", "."]);
    git(&r.tree, &["commit", "-q", "-m", "work"]);
    git(&r.tree, &["reset", "-q", "--hard", "HEAD~1"]);
    r.age();
    let w = r.item().worktree.unwrap();
    assert_eq!(w.unpublished_commits, Some(0));
    assert_eq!(w.status, WorktreeStatus::PendingCommits);
}

#[test]
fn ignored_state_never_becomes_disposable() {
    for rel in [
        "local.db",
        ".env",
        ".claude/session.json",
        "scratch/state.json",
        "node_modules/package/local.db",
        "node_modules/package/.env",
        "node_modules/package/.git/config",
    ] {
        let r = repo("ignored");
        let p = r.tree.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, "state").unwrap();
        r.age();
        let f = r.item();
        assert_eq!(
            f.worktree.as_ref().unwrap().status,
            WorktreeStatus::LocalData,
            "{rel}: {:?}",
            f.reason
        );
        assert!(f.worktree.unwrap().removal_context.is_none());
        assert!(f.manifest.entries.is_empty());
    }
}

#[test]
fn regenerable_ignored_directory_with_tracked_marker_is_allowed() {
    let r = repo("regenerable");
    fs::create_dir_all(r.tree.join("node_modules/pkg")).unwrap();
    fs::write(r.tree.join("node_modules/pkg/index.js"), "x").unwrap();
    r.age();
    let f = r.item();
    assert_eq!(f.state, FindingState::Ready, "{:?}", f.reason);
}

#[test]
fn usage_and_incomplete_inventory_fail_closed() {
    let r = repo("usage");
    let open = ProcessInventory {
        listed: true,
        open_paths: vec![r.tree.join("README.md")],
        ..Default::default()
    };
    let f = r.fx.finding(&r.fx.scan_with(&open, ScanMode::Worktrees), &r.tree);
    assert_eq!(f.worktree.unwrap().status, WorktreeStatus::InUse);
    let mut cmd = ProcessInventory::empty_complete();
    cmd.processes.push(sniff_core::procs::ProcessInfo {
        pid: 1,
        comm: "vim".into(),
        command: format!("vim {}/README.md", r.tree.display()),
    });
    let f = r.fx.finding(&r.fx.scan_with(&cmd, ScanMode::Worktrees), &r.tree);
    assert_eq!(f.state, FindingState::InUse);
    let incomplete = ProcessInventory {
        listed: true,
        unreadable: vec![(9, "x".into())],
        ..Default::default()
    };
    let f = r.fx.finding(&r.fx.scan_with(&incomplete, ScanMode::Worktrees), &r.tree);
    assert_eq!(f.state, FindingState::InUse);
}

#[test]
fn hardlink_opened_elsewhere_marks_worktree_in_use() {
    let r = repo("wthardlink");
    let outside = r.fx.home.join("alias");
    fs::hard_link(r.tree.join("README.md"), &outside).unwrap();
    r.age();
    let meta = std::os::unix::fs::MetadataExt::ino(&fs::metadata(&outside).unwrap());
    let dev = std::os::unix::fs::MetadataExt::dev(&fs::metadata(&outside).unwrap());
    let mut inv = ProcessInventory::empty_complete();
    inv.open_inodes.insert((dev, meta));
    let f = r.fx.finding(&r.fx.scan_with(&inv, ScanMode::Worktrees), &r.tree);
    assert_eq!(f.state, FindingState::InUse, "{:?}", f.reason);
    assert_eq!(f.reason.k, "reason.hardlink_open");
}

#[test]
fn locks_hidden_flags_and_local_config_are_preserved() {
    let r = repo("lock");
    git(&r.main, &["worktree", "lock", r.tree.to_str().unwrap()]);
    assert_eq!(r.status(), WorktreeStatus::Locked);

    let r = repo("assume");
    git(&r.tree, &["update-index", "--assume-unchanged", "README.md"]);
    r.age();
    assert_eq!(r.status(), WorktreeStatus::Unverified);

    let r = repo("cfgwt");
    git(&r.main, &["config", "extensions.worktreeConfig", "true"]);
    git(&r.tree, &["config", "--worktree", "user.name", "Local"]);
    r.age();
    assert_eq!(r.status(), WorktreeStatus::LocalData);

    let r = repo("oplock");
    let admin = r
        .main
        .join(".git/worktrees")
        .read_dir()
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    fs::write(admin.join("index.lock"), "").unwrap();
    r.age();
    assert_eq!(r.status(), WorktreeStatus::Locked);
}

#[test]
fn unknown_principal_recent_activity_and_partial_scans_are_not_eligible() {
    let r = repo("principal");
    git(&r.main, &["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"]);
    r.age();
    let f = r.item();
    assert_eq!(f.worktree.unwrap().status, WorktreeStatus::Unverified);
    assert_eq!(f.reason.k, "wt.no_principal");

    let r = repo("recent");
    fs::write(r.tree.join("node_modules-not"), "").unwrap_or(());
    let _ = fs::remove_file(r.tree.join("node_modules-not"));
    std::process::Command::new("touch").arg(&r.tree).status().unwrap();
    assert_eq!(r.status(), WorktreeStatus::Recent);

    let r = repo("limit");
    let cat = r.fx.catalog();
    let inv = ProcessInventory::empty_complete();
    let progress = |_m: Msg| {};
    let mut s = sniff_core::scanner::Scanner::new(&cat, &r.fx.prefs, &inv, &progress);
    s.manifest_limit = 2;
    let scan = s.scan(ScanMode::Worktrees);
    let f = r.fx.finding(&scan, &r.tree);
    assert_ne!(f.state, FindingState::Ready);
    assert!(f.worktree.unwrap().removal_context.is_none());
}

#[test]
fn excluding_primary_project_protects_its_external_worktrees() {
    let mut r = repo("exclude");
    r.fx.prefs.exclusions.push(r.main.to_string_lossy().into_owned());
    assert_eq!(r.status(), WorktreeStatus::Excluded);
}

#[test]
fn unauthorized_repository_requires_project_root() {
    let mut r = repo("unauth");
    r.fx.prefs.project_roots.clear();
    // Discovery still needs a start point; scan through the agent root is not
    // used here, so the inspector is called directly.
    let cat = r.fx.catalog();
    let inv = ProcessInventory::empty_complete();
    let insp = sniff_core::worktree::WorktreeInspector::new(&cat, &r.fx.prefs, &inv, store_now(), 180_000);
    let f = insp.inspect_repositories(&[r.main.clone()], &mut []);
    assert_eq!(f[0].reason.k, "wt.add_project_root");
    assert_ne!(f[0].state, FindingState::Ready);
}

#[test]
fn execution_rechecks_commits_and_git_locks_after_process_probe() {
    let mut r = repo("recheck");
    r.fx.prefs.enabled_categories.insert(Category::Worktree);
    let f = r.item();
    assert_eq!(f.state, FindingState::Ready, "{:?}", f.reason);
    let tree = r.tree.clone();
    let report = r.fx.clean_with(
        &[f],
        store_now(),
        false,
        &mut |_| {
            fs::write(tree.join("README.md"), "late edit").unwrap();
            git(&tree, &["commit", "-q", "-am", "late"]);
            None
        },
        &mut |_| {},
    );
    assert!(!report.outcomes[0].removed);
    assert!(r.tree.join("README.md").exists());

    let mut r = repo("latelock");
    r.fx.prefs.enabled_categories.insert(Category::Worktree);
    let f = r.item();
    let admin = r
        .main
        .join(".git/worktrees")
        .read_dir()
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let report = r.fx.clean_with(
        &[f],
        store_now(),
        false,
        &mut |_| {
            fs::write(admin.join("index.lock"), "").unwrap();
            None
        },
        &mut |_| {},
    );
    assert!(!report.outcomes[0].removed);
    assert!(r.tree.exists());
}

#[test]
fn changed_remote_reference_invalidates_plan() {
    let mut r = repo("remoteref");
    r.fx.prefs.enabled_categories.insert(Category::Worktree);
    let f = r.item();
    let main = r.main.clone();
    let report = r.fx.clean_with(
        &[f],
        store_now(),
        false,
        &mut |_| {
            let h = git(&main, &["rev-parse", "HEAD"]);
            git(&main, &["update-ref", "refs/remotes/origin/other", &h]);
            None
        },
        &mut |_| {},
    );
    assert!(!report.outcomes[0].removed);
    assert!(r.tree.exists());
    // A fresh scan is eligible again.
    assert_eq!(r.item().state, FindingState::Ready);
}

#[test]
fn partial_removal_restores_git_marker_and_keeps_late_files() {
    let mut r = repo("partialwt");
    r.fx.prefs.enabled_categories.insert(Category::Worktree);
    let f = r.item();
    let late = r.tree.join("late.txt");
    let mut hook = |rel: &str| {
        if rel == ".git" {
            fs::write(&late, "late").unwrap();
        }
    };
    let report = r.fx.clean_with(&[f], store_now(), false, &mut |_| None, &mut hook);
    let o = &report.outcomes[0];
    assert!(!o.removed && o.partially_removed, "{o:?}");
    assert!(late.exists());
    assert!(r.tree.join(".git").exists());
    assert!(!git(&r.tree, &["rev-parse", "HEAD"]).is_empty());
}

#[test]
fn inspection_never_runs_repository_filters() {
    let r = repo("filters");
    let marker = r.fx.root.join("filter-ran");
    git(
        &r.main,
        &["config", "filter.evil.clean", &format!("touch {}", marker.display())],
    );
    git(
        &r.main,
        &["config", "filter.evil.process", &format!("touch {}", marker.display())],
    );
    fs::write(r.main.join(".gitattributes"), "*.md filter=evil\n").unwrap();
    std::process::Command::new("touch")
        .arg(r.tree.join("README.md"))
        .status()
        .unwrap();
    r.age();
    let _ = r.item();
    assert!(!marker.exists(), "a clean/process filter was executed");
}

#[test]
fn symlinked_worktree_or_admin_dir_is_never_a_candidate() {
    let r = repo("symwt");
    let moved = r.fx.home.join("moved-tree");
    fs::rename(&r.tree, &moved).unwrap();
    std::os::unix::fs::symlink(&moved, &r.tree).unwrap();
    let f = r.item();
    assert_ne!(f.state, FindingState::Ready);

    let r = repo("symadmin");
    let admin = r
        .main
        .join(".git/worktrees")
        .read_dir()
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let moved = r.fx.home.join("moved-admin");
    fs::rename(&admin, &moved).unwrap();
    std::os::unix::fs::symlink(&moved, &admin).unwrap();
    let f = r.item();
    assert_ne!(f.state, FindingState::Ready);
}

#[test]
fn primary_checkout_is_never_a_candidate() {
    let r = repo("primary");
    let scan = r.scan();
    assert!(scan.findings.iter().all(|f| Path::new(&f.path) != r.main));
}

#[test]
fn auxiliary_metadata_does_not_hide_commits_or_usage() {
    let r = repo("fetchhead");
    let admin = r
        .main
        .join(".git/worktrees")
        .read_dir()
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    fs::write(admin.join("FETCH_HEAD"), "x").unwrap();
    r.age();
    let f = r.item();
    assert_eq!(f.worktree.unwrap().status, WorktreeStatus::LocalData);
    assert!(f.details.iter().any(|d| d.k == "detail.local_metadata"));
}

#[test]
fn stat_settings_cannot_hide_same_size_edits() {
    let r = repo("checkstat");
    git(&r.main, &["config", "core.trustctime", "false"]);
    git(&r.main, &["config", "core.checkStat", "minimal"]);
    let p = r.tree.join("README.md");
    let before = fs::metadata(&p).unwrap().modified().unwrap();
    fs::write(&p, "HELLO").unwrap();
    fs::File::options()
        .write(true)
        .open(&p)
        .unwrap()
        .set_modified(before)
        .unwrap();
    assert_eq!(r.status(), WorktreeStatus::LocalChanges);
}

fn admin_of(r: &Repo) -> PathBuf {
    r.main
        .join(".git/worktrees")
        .read_dir()
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path()
}

#[test]
fn known_codex_and_git_metadata_is_accepted_only_in_exact_form() {
    let accept: &[(&str, &str)] = &[
        ("codex-thread.json", r#"{"version":1,"ownerThreadId":"019a-thread"}"#),
        ("config.worktree", "[codex]\n\tlocalEnvironmentConfigPath = __none__\n"),
        ("MERGE_RR", ""),
        ("FETCH_HEAD", "04a7b5e6e0978ba4055d8ee09416a3a47843ef7a\t\tbranch 'main' of https://example.invalid/repo\nfb26159235f39a78db1b246680824d867bf3cf2c\tnot-for-merge\tbranch 'x'\n"),
    ];
    let r = repo("knownmeta");
    for (name, body) in accept {
        fs::write(admin_of(&r).join(name), body).unwrap();
    }
    r.age();
    let f = r.item();
    assert_eq!(f.state, FindingState::Ready, "{:?} {:?}", f.reason, f.details);
    assert_eq!(f.details.iter().filter(|d| d.k == "detail.known_metadata").count(), 4);

    let r = repo("emptyfetch");
    fs::write(admin_of(&r).join("FETCH_HEAD"), "").unwrap();
    r.age();
    assert_eq!(r.item().state, FindingState::Ready);

    let reject: &[(&str, &str)] = &[
        (
            "codex-thread.json",
            r#"{"version":1,"ownerThreadId":"x","notes":"local"}"#,
        ),
        (
            "config.worktree",
            "[codex]\n\tlocalEnvironmentConfigPath = __none__\n[core]\n\tsparseCheckout = true\n",
        ),
        ("config.worktree", "[include]\n\tpath = /tmp/other\n"),
        ("MERGE_RR", "conflict-id\tpath\n"),
        ("FETCH_HEAD", "x"),
        ("custom-state", "anything"),
    ];
    for (name, body) in reject {
        let r = repo("unknownmeta");
        fs::write(admin_of(&r).join(name), body).unwrap();
        r.age();
        assert_eq!(r.status(), WorktreeStatus::LocalData, "{name}: {body}");
    }
}
