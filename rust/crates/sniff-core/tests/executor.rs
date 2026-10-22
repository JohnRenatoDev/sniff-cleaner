mod common;

use common::*;
use sniff_core::fsx;
use sniff_core::model::*;
use sniff_core::procs::ProcessInventory;
use sniff_core::store::{self, Dirs, OperationLock, StoreError};
use std::fs;
use std::os::unix::fs::symlink;
use std::path::Path;

fn npm_cache(fx: &Fixture) -> std::path::PathBuf {
    fx.home.join(".npm/_cacache")
}

#[test]
fn removes_only_recognized_cache_and_measures_free_space() {
    let fx = Fixture::new("basic");
    fx.write(".npm/_cacache/index-v5/literal $(do-not-execute)", "cache");
    fx.write(".npm/_cacache/content-v2/sha512/ab/cd", &"x".repeat(10_000));
    let source = fx.write("projects/app/src/main.rs", "fn main() {}");
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    assert_eq!(f.state, FindingState::Ready, "{:?}", f.reason);
    assert!(f.allocated_bytes > 0 && !f.partial_measurement);
    let report = fx.clean(&[f], scan.date);
    assert!(removed(&report, &npm_cache(&fx)), "{:?}", report.outcomes);
    assert!(!npm_cache(&fx).exists());
    assert!(fx.home.join(".npm").exists(), "only the rule's target is removed");
    assert_eq!(fs::read_to_string(source).unwrap(), "fn main() {}");
    assert!(report.available_before.is_some() && report.available_after.is_some());
}

#[test]
fn exclusion_inside_candidate_preserves_entire_tree() {
    let mut fx = Fixture::new("exclusion");
    let keep = fx.write(".npm/_cacache/keep/me", "x");
    fx.prefs
        .exclusions
        .push(keep.parent().unwrap().to_string_lossy().into_owned());
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    assert_eq!(f.state, FindingState::Protected);
    assert_eq!(f.reason.k, "reason.excluded");
    // Even a forged "ready" item is refused at execution.
    let mut forged = f.clone();
    forged.state = FindingState::Ready;
    let report = fx.clean(&[forged], scan.date);
    assert!(!removed(&report, &npm_cache(&fx)));
    assert!(keep.exists());
}

#[test]
fn internal_symlink_is_removed_as_link_and_target_survives() {
    let fx = Fixture::new("symlink");
    let outside = fx.write("important/data.txt", "precious");
    fx.write(".npm/_cacache/a", "x");
    symlink(&outside, npm_cache(&fx).join("link-to-outside")).unwrap();
    symlink(outside.parent().unwrap(), npm_cache(&fx).join("dir-link")).unwrap();
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    let report = fx.clean(&[f], scan.date);
    assert!(removed(&report, &npm_cache(&fx)), "{:?}", report.outcomes);
    assert_eq!(fs::read_to_string(&outside).unwrap(), "precious");
}

#[test]
fn symlink_ancestor_is_refused() {
    let fx = Fixture::new("ancestor");
    fx.write("elsewhere/cache/file", "x");
    fs::create_dir_all(fx.home.join(".npm")).unwrap();
    symlink(fx.home.join("elsewhere/cache"), npm_cache(&fx)).unwrap();
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    assert_ne!(f.state, FindingState::Ready);
    let mut forged = f.clone();
    forged.state = FindingState::Ready;
    let report = fx.clean(&[forged], scan.date);
    assert!(!removed(&report, &npm_cache(&fx)));
    assert!(fx.home.join("elsewhere/cache/file").exists());
}

#[test]
fn changed_content_invalidates_plan() {
    let fx = Fixture::new("changed");
    let file = fx.write(".npm/_cacache/a", "x");
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    fs::write(&file, "changed!").unwrap();
    let report = fx.clean(&[f.clone()], scan.date);
    assert!(!removed(&report, &npm_cache(&fx)));
    assert_eq!(outcome(&report, &npm_cache(&fx)).message.k, "exec.content_changed");
    fx.write(".npm/_cacache/new-file", "late");
    let report = fx.clean(&[f], scan.date);
    assert!(!removed(&report, &npm_cache(&fx)));
    assert!(file.exists());
}

#[test]
fn rechecks_manifest_after_slow_usage_probe() {
    let fx = Fixture::new("slowprobe");
    let file = fx.write(".npm/_cacache/a", "x");
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    let report = fx.clean_with(
        &[f],
        scan.date,
        false,
        &mut |_| {
            fs::write(&file, "written during probe").unwrap();
            None
        },
        &mut |_| {},
    );
    assert!(!removed(&report, &npm_cache(&fx)));
    assert_eq!(outcome(&report, &npm_cache(&fx)).message.k, "exec.changed_during_check");
    assert!(file.exists());
}

#[test]
fn in_use_item_is_preserved() {
    let fx = Fixture::new("inuse");
    fx.write(".npm/_cacache/a", "x");
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    let report = fx.clean_with(
        &[f],
        scan.date,
        false,
        &mut |_| Some(Msg::new("reason.open_by_process")),
        &mut |_| {},
    );
    assert!(!removed(&report, &npm_cache(&fx)));
    assert!(npm_cache(&fx).exists());
}

#[test]
fn process_probe_finds_open_hardlink_by_inode_and_working_directory() {
    let fx = Fixture::new("hardlinkprobe");
    let inside = fx.write(".npm/_cacache/blob", "x");
    let outside = fx.home.join("outside-alias");
    fs::hard_link(&inside, &outside).unwrap();
    let manifest = fsx::build_manifest(&npm_cache(&fx), &fsx::WalkOptions::default()).unwrap();
    // A child process holds the hardlink open through the outside path.
    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .stdin(fs::File::open(&outside).unwrap())
        .spawn()
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(150));
    let inv = ProcessInventory::capture();
    let reason = inv.reason(&npm_cache(&fx), &[], Some(&manifest));
    // A child whose working directory is inside the candidate.
    let mut cwd_child = std::process::Command::new("sleep")
        .arg("30")
        .current_dir(npm_cache(&fx))
        .spawn()
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(150));
    let inv2 = ProcessInventory::capture();
    let reason2 = inv2.reason(&npm_cache(&fx), &[], None);
    child.kill().unwrap();
    cwd_child.kill().unwrap();
    let _ = child.wait();
    let _ = cwd_child.wait();
    if !inv.is_complete() {
        assert_eq!(reason.unwrap().k, "reason.process_inventory_incomplete");
        return;
    }
    assert_eq!(reason.expect("hardlink must be detected").k, "reason.hardlink_open");
    assert_eq!(reason2.expect("cwd must be detected").k, "reason.open_by_process");
}

#[test]
fn incomplete_inventory_fails_closed() {
    let fx = Fixture::new("incomplete");
    fx.write(".npm/_cacache/a", "x");
    let inv = ProcessInventory {
        listed: true,
        unreadable: vec![(1, "x".into())],
        ..Default::default()
    };
    let scan = fx.scan_with(&inv, ScanMode::Quick);
    let f = fx.finding(&scan, &npm_cache(&fx));
    assert_eq!(f.state, FindingState::InUse);
    assert!(scan
        .notices
        .iter()
        .any(|n| n.k == "notice.process_inventory_incomplete"));
}

#[test]
fn expired_plan_and_disabled_category_are_refused() {
    let mut fx = Fixture::new("expired");
    fx.write(".npm/_cacache/a", "x");
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    let report = fx.clean(&[f.clone()], scan.date - 901);
    assert_eq!(outcome(&report, &npm_cache(&fx)).message.k, "exec.expired");
    fx.prefs.enabled_categories.remove(&Category::Npm);
    let report = fx.clean(&[f], scan.date);
    assert_eq!(outcome(&report, &npm_cache(&fx)).message.k, "exec.category_not_allowed");
    assert!(npm_cache(&fx).exists());
}

#[test]
fn forged_runtime_and_worktree_cannot_enter_executor() {
    let fx = Fixture::new("forged");
    let primary = fx.home.join(".cache/codex-runtimes/codex-primary-runtime");
    fx.write(".cache/codex-runtimes/codex-primary-runtime/runtime.json", "{}");
    age(&fx.home.join(".cache/codex-runtimes"), 60);
    let manifest = fsx::build_manifest(&primary, &fsx::WalkOptions::default()).unwrap();
    let forged = Finding {
        path: primary.to_string_lossy().into_owned(),
        title: Msg::new("title.plain").arg("x"),
        category: Category::RuntimeInstalls,
        rule_id: "codex-install".into(),
        state: FindingState::Ready,
        reason: Msg::new("reason.rule_ready"),
        logical_bytes: 0,
        allocated_bytes: 0,
        exclusive_bytes: 0,
        shared_links: false,
        partial_measurement: false,
        details: vec![],
        manifest: manifest.clone(),
        worktree: None,
    };
    let mut wt = forged.clone();
    wt.rule_id = "git-worktree".into();
    wt.category = Category::Worktree;
    let mut prefs_fx = fx;
    prefs_fx.prefs.enabled_categories.insert(Category::Worktree);
    let report = prefs_fx.clean(&[forged], store::now_secs());
    assert!(!report.outcomes[0].removed);
    let report = prefs_fx.clean(&[wt], store::now_secs());
    assert!(!report.outcomes[0].removed);
    assert!(primary.join("runtime.json").exists());
}

#[test]
fn partial_failure_does_not_hide_successful_removal() {
    let fx = Fixture::new("twoitems");
    fx.write(".npm/_cacache/a", "x");
    let pip = fx.write(".cache/pip/http-v2/b", "y");
    let scan = fx.scan();
    let a = fx.finding(&scan, &npm_cache(&fx));
    let b = fx.finding(&scan, &fx.home.join(".cache/pip"));
    fs::write(&pip, "changed").unwrap();
    let report = fx.clean(&[a, b], scan.date);
    assert!(removed(&report, &npm_cache(&fx)));
    assert!(!removed(&report, &fx.home.join(".cache/pip")));
    assert!(!report.all_removed());
    assert!(pip.exists());
}

#[test]
fn automatic_cleanup_refuses_manual_categories() {
    let mut fx = Fixture::new("automatic");
    fx.prefs.enabled_categories.insert(Category::Logs);
    fx.write(".codex/log/old.log", "log");
    age(&fx.home.join(".codex/log"), 90);
    let scan = fx.scan();
    let f = fx.finding(&scan, &fx.home.join(".codex/log/old.log"));
    assert_eq!(f.state, FindingState::Ready, "{:?}", f.reason);
    let report = fx.clean_with(&[f.clone()], scan.date, true, &mut |_| None, &mut |_| {});
    assert_eq!(report.outcomes[0].message.k, "exec.category_not_allowed");
    // Manual, explicit cleanup of the same log file works.
    let report = fx.clean(&[f], scan.date);
    assert!(report.outcomes[0].removed, "{:?}", report.outcomes);
}

#[test]
fn newest_file_controls_retention() {
    let fx = Fixture::new("retention");
    let dir = fx.home.join(".cache/codex-runtimes/codex-runtime-install-abc123");
    fx.write(".cache/codex-runtimes/codex-runtime-install-abc123/payload/old", "x");
    age(&dir, 60);
    fx.write(".cache/codex-runtimes/codex-runtime-install-abc123/payload/fresh", "y");
    let scan = fx.scan();
    let f = fx.finding(&scan, &dir);
    assert_eq!(f.state, FindingState::Protected);
    assert_eq!(f.reason.k, "reason.recent");
    // The primary runtime is never a candidate.
    fx.write(".cache/codex-runtimes/codex-primary-runtime/runtime.json", "{}");
    let scan = fx.scan();
    assert!(scan.findings.iter().all(|f| !f.path.ends_with("codex-primary-runtime")));
}

#[test]
fn npx_with_mcp_is_preserved_even_when_forged_ready() {
    let fx = Fixture::new("npx");
    let env = fx.home.join(".npm/_npx/0123abcd");
    fx.write(
        ".npm/_npx/0123abcd/package-lock.json",
        r#"{"packages":{"node_modules/@modelcontextprotocol/sdk":{}}}"#,
    );
    let plain = fx.home.join(".npm/_npx/feedbeef");
    fx.write(
        ".npm/_npx/feedbeef/package-lock.json",
        r#"{"packages":{"node_modules/left-pad":{}}}"#,
    );
    let linked = fx.home.join(".npm/_npx/11111111");
    fx.write(".npm/_npx/11111111/real.json", "{}");
    symlink(linked.join("real.json"), linked.join("package-lock.json")).unwrap();
    age(&fx.home.join(".npm/_npx"), 60);
    let mut fx = fx;
    fx.prefs.enabled_categories.insert(Category::Npx);
    let scan = fx.scan();
    assert_eq!(fx.finding(&scan, &env).reason.k, "reason.npx_mcp");
    assert_eq!(fx.finding(&scan, &linked).reason.k, "reason.npx_mcp");
    let ok = fx.finding(&scan, &plain);
    assert_eq!(ok.state, FindingState::Ready, "{:?}", ok.reason);
    // Forge the MCP environment as ready with a valid manifest.
    let mut forged = ok.clone();
    forged.path = env.to_string_lossy().into_owned();
    forged.manifest = fsx::build_manifest(&env, &fsx::WalkOptions::default()).unwrap();
    let report = fx.clean(&[forged, ok], scan.date);
    assert!(!removed(&report, &env));
    assert!(removed(&report, &plain));
    // Unfiltered default plans never include npx.
    let scan = fx.scan();
    assert!(sniff_core::plan::select(Some(&scan), &fx.prefs, &[], &[], &fx.home, scan.date).is_err());
}

#[test]
fn corrupt_state_is_never_silently_overwritten() {
    let fx = Fixture::new("corrupt");
    let dirs = Dirs::for_home(&fx.home);
    fs::create_dir_all(&dirs.state).unwrap();
    fs::write(dirs.history_file(), b"{ not json").unwrap();
    assert!(matches!(store::load_state(&dirs), Err(StoreError::Corrupt(..))));
    let state = PersistedState::default();
    assert!(store::save_state(&dirs, &state).is_err());
    assert_eq!(fs::read(dirs.history_file()).unwrap(), b"{ not json");
    // Settings: symlinked file is refused.
    fs::create_dir_all(&dirs.config).unwrap();
    let target = fx.write("elsewhere.json", "{}");
    symlink(&target, dirs.settings_file()).unwrap();
    assert!(store::load_prefs(&dirs).is_err());
    assert_eq!(fs::read_to_string(&target).unwrap(), "{}");
}

#[test]
fn state_files_are_private_and_round_trip() {
    let fx = Fixture::new("private");
    fx.write(".npm/_cacache/a", "x");
    let dirs = Dirs::for_home(&fx.home);
    let mut state = store::load_state(&dirs).unwrap();
    state.last_scan = Some(fx.scan());
    store::save_state(&dirs, &state).unwrap();
    store::save_prefs(&dirs, &fx.prefs).unwrap();
    use std::os::unix::fs::PermissionsExt;
    for p in [dirs.history_file(), dirs.settings_file()] {
        assert_eq!(
            fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600,
            "{}",
            p.display()
        );
    }
    assert_eq!(fs::metadata(&dirs.state).unwrap().permissions().mode() & 0o777, 0o700);
    let back = store::load_state(&dirs).unwrap();
    assert_eq!(
        back.last_scan.unwrap().findings.len(),
        state.last_scan.unwrap().findings.len()
    );
}

#[test]
fn lock_prevents_concurrent_operations() {
    let fx = Fixture::new("lock");
    let dirs = Dirs::for_home(&fx.home);
    let held = OperationLock::acquire(&dirs, false).unwrap();
    assert!(matches!(OperationLock::acquire(&dirs, false), Err(StoreError::Busy)));
    drop(held);
    assert!(OperationLock::acquire(&dirs, false).is_ok());
}

#[test]
fn partial_directory_removal_reports_what_was_removed() {
    let fx = Fixture::new("partial");
    fx.write(".npm/_cacache/a/1", "x");
    fx.write(".npm/_cacache/b/2", "y");
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    let late = npm_cache(&fx).join("late-writer");
    let mut hook = |rel: &str| {
        if rel.is_empty() {
            fs::write(&late, "appeared").unwrap();
        }
    };
    let report = fx.clean_with(&[f], scan.date, false, &mut |_| None, &mut hook);
    let o = outcome(&report, &npm_cache(&fx));
    assert!(!o.removed && o.partially_removed, "{o:?}");
    assert!(late.exists());
    assert!(!npm_cache(&fx).join("a").exists());
    // Applying the report marks the item preserved with no manifest.
    let mut state = PersistedState {
        last_scan: Some(scan),
        ..Default::default()
    };
    sniff_core::executor::apply_report(&mut state, &report);
    let after = state.last_scan.unwrap();
    let f = after
        .findings
        .iter()
        .find(|f| Path::new(&f.path) == npm_cache(&fx))
        .unwrap();
    assert_eq!(f.state, FindingState::Protected);
    assert!(f.manifest.entries.is_empty() && f.partial_measurement);
}

#[test]
fn hardlinks_inside_candidate_do_not_invalidate_removal_and_external_alias_survives() {
    let fx = Fixture::new("hardlinks");
    let a = fx.write(".npm/_cacache/a", &"z".repeat(8192));
    fs::hard_link(&a, npm_cache(&fx).join("b")).unwrap();
    let ext_src = fx.write(".npm/_cacache/shared", "shared");
    let outside = fx.home.join("keep-alias");
    fs::hard_link(&ext_src, &outside).unwrap();
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    assert!(f.shared_links);
    assert!(f.details.iter().any(|d| d.k == "detail.external_links"));
    let report = fx.clean(&[f], scan.date);
    assert!(removed(&report, &npm_cache(&fx)), "{:?}", report.outcomes);
    assert_eq!(fs::read_to_string(&outside).unwrap(), "shared");
}

#[test]
fn plan_files_are_private_never_overwritten_and_refuse_symlinks_and_foreign_homes() {
    let fx = Fixture::new("planfile");
    fx.write(".npm/_cacache/a", "x");
    let scan = fx.scan();
    let items = sniff_core::plan::select(Some(&scan), &fx.prefs, &[], &[], &fx.home, scan.date).unwrap();
    let doc = sniff_core::plan::PlanDocument {
        schema_version: 1,
        home: fx.catalog().home.to_string_lossy().into_owned(),
        scanned_at: scan.date,
        created_at: scan.date,
        findings: items,
    };
    let p = fx.root.join("plan.json");
    sniff_core::plan::write_plan(&p, &doc).unwrap();
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
    assert!(sniff_core::plan::write_plan(&p, &doc).is_err(), "never overwrite");
    let link = fx.root.join("plan-link.json");
    symlink(&p, &link).unwrap();
    assert!(sniff_core::plan::read_plan(&link, &fx.catalog().home, scan.date).is_err());
    assert!(sniff_core::plan::read_plan(&p, &fx.catalog().home, scan.date).is_ok());
    assert!(sniff_core::plan::read_plan(&p, Path::new("/nonexistent-home"), scan.date).is_err());
    assert!(sniff_core::plan::read_plan(&p, &fx.catalog().home, scan.date + 901).is_err());
}

#[test]
fn aggressive_symlink_swaps_during_removal_never_reach_outside() {
    for round in 0..8 {
        let fx = Fixture::new(&format!("race{round}"));
        let outside = fx.write("precious/data.txt", "keep me");
        for i in 0..200 {
            fx.write(&format!(".npm/_cacache/sub/f{i}"), "x");
        }
        fx.write(".npm/_cacache/other/a", "y");
        let scan = fx.scan();
        let f = fx.finding(&scan, &npm_cache(&fx));
        let sub = npm_cache(&fx).join("sub");
        let parked = fx.home.join("parked");
        let target = outside.parent().unwrap().to_path_buf();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stop.clone();
        let (s2, p2, t2) = (sub.clone(), parked.clone(), target.clone());
        let swapper = std::thread::spawn(move || {
            while !flag.load(std::sync::atomic::Ordering::Relaxed) {
                if fs::rename(&s2, &p2).is_ok() {
                    let _ = symlink(&t2, &s2);
                    std::thread::yield_now();
                    let _ = fs::remove_file(&s2);
                    let _ = fs::rename(&p2, &s2);
                }
            }
        });
        let _ = fx.clean(&[f], scan.date);
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        swapper.join().unwrap();
        assert_eq!(fs::read_to_string(&outside).unwrap(), "keep me", "round {round}");
    }
}

#[test]
fn recent_logs_are_summarized_per_folder_and_old_ones_listed() {
    let mut fx = Fixture::new("logs");
    fx.prefs.enabled_categories.insert(Category::Logs);
    for i in 0..5 {
        fx.write(&format!(".cache/claude-cli-nodejs/proj/mcp-logs-x/{i}.jsonl"), "{}");
        fx.write(&format!(".cache/claude-cli-nodejs/other/mcp-logs-z/{i}.jsonl"), "{}");
    }
    let old = fx.write(".cache/claude-cli-nodejs/proj/mcp-logs-y/old.jsonl", "{}");
    age(&fx.home.join(".cache/claude-cli-nodejs/proj/mcp-logs-y"), 90);
    fx.write(".cache/claude-cli-nodejs/proj/not-logs/skip.jsonl", "{}");
    let scan = fx.scan();
    let logs: Vec<_> = scan.findings.iter().filter(|f| f.category == Category::Logs).collect();
    assert_eq!(logs.len(), 2, "{:?}", logs.iter().map(|f| &f.path).collect::<Vec<_>>());
    let group = logs.iter().find(|f| f.title.k == "title.recent_logs").unwrap();
    assert_eq!(group.state, FindingState::Protected);
    assert!(group.manifest.entries.is_empty());
    let ready = fx.finding(&scan, &old);
    assert_eq!(ready.state, FindingState::Ready);
    // A forged "ready" group is refused.
    let mut forged = (*group).clone();
    forged.state = FindingState::Ready;
    forged.manifest = ready.manifest.clone();
    let report = fx.clean(&[forged], scan.date);
    assert!(!report.outcomes[0].removed);
}

#[test]
fn exclusive_estimate_excludes_space_shared_outside() {
    let fx = Fixture::new("exclusive");
    let a = fx.write(".npm/_cacache/a", &"z".repeat(64 * 1024));
    fs::hard_link(&a, fx.home.join("project-link")).unwrap();
    fx.write(".npm/_cacache/b", &"q".repeat(64 * 1024));
    let scan = fx.scan();
    let f = fx.finding(&scan, &npm_cache(&fx));
    assert!(f.manifest.exclusive_allocated_bytes < f.manifest.allocated_bytes);
    assert!(f.manifest.exclusive_allocated_bytes >= 64 * 1024);
}
