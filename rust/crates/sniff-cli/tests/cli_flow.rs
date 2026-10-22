//! End-to-end CLI flows against a fixture home (`SNIFF_HOME`). Never touches
//! the real user's data.

use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

struct Home {
    root: PathBuf,
    home: PathBuf,
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn home(name: &str) -> Home {
    let root = std::env::temp_dir().join(format!("sniff-cli-tests-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("home")).unwrap();
    let root = fs::canonicalize(root).unwrap();
    Home {
        home: root.join("home"),
        root,
    }
}

impl Home {
    fn sniff(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_sniff"))
            .args(args)
            .env("SNIFF_HOME", &self.home)
            .env("LANG", "en_US.UTF-8")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }
    fn json(&self, args: &[&str]) -> (i32, Value) {
        let out = self.sniff(args);
        let v = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!(
                "{args:?}: {e}\n{}\n{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            )
        });
        (out.status.code().unwrap_or(-1), v)
    }
    fn write(&self, rel: &str, content: &str) -> PathBuf {
        let p = self.home.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, content).unwrap();
        p
    }
}

/// Content snapshot of every file under `dir` (path → bytes).
fn snapshot(dir: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut out = BTreeMap::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in fs::read_dir(&d).unwrap().flatten() {
            let ft = e.file_type().unwrap();
            if ft.is_dir() {
                stack.push(e.path());
            } else if ft.is_file() {
                out.insert(e.path(), fs::read(e.path()).unwrap());
            }
        }
    }
    out
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("/usr/bin/git")
        .args([
            "-c",
            "user.name=F",
            "-c",
            "user.email=f@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
        ])
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim_end().to_string()
}

fn age(path: &Path, days: i64) {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
        - days * 86_400;
    let stamp = format!("@{secs}");
    assert!(Command::new("find")
        .arg(path)
        .args(["-exec", "touch", "-h", "-d", &stamp, "{}", "+"])
        .status()
        .unwrap()
        .success());
}

#[test]
fn scan_review_plan_clean_cache_flow() {
    let h = home("cache");
    h.write(".npm/_cacache/index-v5/a", "x");
    h.write(".npm/_cacache/content-v2/b", &"y".repeat(5000));
    h.write(".cache/pip/http-v2/c", "pip");
    h.write("projects/app/src/lib.rs", "pub fn keep() {}");
    h.write(".claude/settings.json", "{}");
    h.write(".codex/sessions/s.jsonl", "{}");
    let keep_before = snapshot(&h.home.join("projects"));
    let claude_before = snapshot(&h.home.join(".claude"));

    let (code, scan) = h.json(&["scan", "--quick", "--json"]);
    assert_eq!(code, 0);
    let items = scan["items"].as_array().unwrap();
    assert!(items.iter().any(|i| i["category"] == "npm" && i["state"] == "ready"));
    assert!(items.iter().all(|i| !i["path"].as_str().unwrap().contains("/.claude")));

    let (_, list) = h.json(&["list", "--ready", "--json"]);
    assert_eq!(list["items"].as_array().unwrap().len(), 2);

    // Preview writes nothing.
    let (code, preview) = h.json(&["plan", "--category", "npm", "--json"]);
    assert_eq!(code, 0);
    assert!(preview.get("planFile").is_none());

    let plan = h.root.join("cleanup-plan.json");
    let (code, saved) = h.json(&[
        "plan",
        "--category",
        "npm",
        "--output",
        plan.to_str().unwrap(),
        "--json",
    ]);
    assert_eq!(code, 0, "{saved}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(fs::metadata(&plan).unwrap().permissions().mode() & 0o777, 0o600);
    // Never overwrites an existing plan file.
    let (code, err) = h.json(&[
        "plan",
        "--category",
        "npm",
        "--output",
        plan.to_str().unwrap(),
        "--json",
    ]);
    assert_eq!(code, 2, "{err}");

    // Without --yes and without a terminal: consent not given.
    let out = h.sniff(&["clean", "--plan", plan.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(3));
    assert!(h.home.join(".npm/_cacache").exists());

    let (code, report) = h.json(&["clean", "--plan", plan.to_str().unwrap(), "--yes", "--json"]);
    assert_eq!(code, 0, "{report}");
    assert_eq!(report["outcomes"][0]["removed"], true);
    assert!(report["availableBefore"].is_u64() && report["availableAfter"].is_u64());
    assert!(!h.home.join(".npm/_cacache").exists());
    assert!(
        h.home.join(".cache/pip/http-v2/c").exists(),
        "unselected category stays"
    );
    assert_eq!(snapshot(&h.home.join("projects")), keep_before);
    assert_eq!(snapshot(&h.home.join(".claude")), claude_before);
    assert!(h.home.join(".codex/sessions/s.jsonl").exists());

    let (_, history) = h.json(&["history", "--json"]);
    assert_eq!(history.as_array().unwrap().len(), 1);
}

#[test]
fn disabling_category_after_planning_keeps_items_with_exit_4() {
    let h = home("disable");
    h.write(".npm/_cacache/a", "x");
    h.json(&["scan", "--quick", "--json"]);
    let plan = h.root.join("p.json");
    h.json(&[
        "plan",
        "--category",
        "npm",
        "--output",
        plan.to_str().unwrap(),
        "--json",
    ]);
    let (code, _) = h.json(&["config", "--disable", "npm", "--json"]);
    assert_eq!(code, 0);
    let (code, report) = h.json(&["clean", "--plan", plan.to_str().unwrap(), "--yes", "--json"]);
    assert_eq!(code, 4, "{report}");
    assert!(h.home.join(".npm/_cacache/a").exists());
}

#[test]
fn worktree_only_flow_requires_enablement_and_explicit_filter() {
    let h = home("worktree");
    let main = h.home.join("Work/main");
    fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "-q", "-b", "trunk-real"]);
    fs::write(main.join("README.md"), "hi").unwrap();
    git(&main, &["add", "."]);
    git(&main, &["commit", "-q", "-m", "init"]);
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
    let tree = h.home.join("elsewhere/feature-tree");
    fs::create_dir_all(tree.parent().unwrap()).unwrap();
    git(
        &main,
        &["worktree", "add", "-q", "-b", "feature", tree.to_str().unwrap()],
    );
    let cache = h.write(".npm/_cacache/a", "x");
    age(&tree, 60);
    age(&main.join(".git/worktrees"), 60);
    let main_before = snapshot(&main);

    let (code, _) = h.json(&["config", "--project", h.home.join("Work").to_str().unwrap(), "--json"]);
    assert_eq!(code, 0);
    let (code, scan) = h.json(&["scan", "--worktrees", "--json"]);
    assert_eq!(code, 0);
    let items = scan["items"].as_array().unwrap();
    assert_eq!(items.len(), 1, "{scan}");
    let it = &items[0];
    assert_eq!(it["category"], "worktree");
    assert_eq!(it["state"], "ready", "{it}");
    assert_eq!(it["worktree"]["status"], "idle");
    assert!(it["worktree"].get("removalContext").is_none());
    assert!(it.get("manifest").is_none());

    let (_, listed) = h.json(&["list", "--category", "worktree", "--filter", "pending", "--json"]);
    assert_eq!(listed["items"].as_array().unwrap().len(), 0);
    let (_, listed) = h.json(&["list", "--category", "worktree", "--search", "feature-tree", "--json"]);
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let plan = h.root.join("wt.json");
    let (code, _) = h.json(&[
        "plan",
        "--category",
        "worktree",
        "--output",
        plan.to_str().unwrap(),
        "--json",
    ]);
    assert_eq!(code, 2, "worktree category is disabled by default");
    h.json(&["config", "--enable", "worktree", "--json"]);
    let (code, _) = h.json(&["plan", "--json"]);
    assert_eq!(code, 2, "unfiltered plans never include worktrees");
    let (code, p) = h.json(&[
        "plan",
        "--category",
        "worktree",
        "--output",
        plan.to_str().unwrap(),
        "--json",
    ]);
    assert_eq!(code, 0, "{p}");
    let (code, report) = h.json(&["clean", "--plan", plan.to_str().unwrap(), "--yes", "--json"]);
    assert_eq!(code, 0, "{report}");
    assert!(!tree.exists());
    assert!(cache.exists(), "cache untouched by a worktree plan");
    assert!(
        !git(&main, &["rev-parse", "--verify", "refs/heads/feature"]).is_empty(),
        "branch kept"
    );
    let mut after = snapshot(&main);
    let mut before = main_before;
    // Git's own bookkeeping for the removed worktree is the only change.
    after.retain(|p, _| !p.to_string_lossy().contains("/.git/"));
    before.retain(|p, _| !p.to_string_lossy().contains("/.git/"));
    assert_eq!(after, before);
}

#[test]
fn usage_errors_and_json_errors() {
    let h = home("errors");
    for (args, code) in [
        (vec!["clean", "--yes"], 2),
        (vec!["plan", "--path", "/a", "--category", "npm"], 2),
        (vec!["scan", "--language", "fr"], 2),
        (vec!["list", "--json"], 2),
        (vec!["plan", "--category", "homebrew"], 2),
        (vec!["config", "--enable", "docker"], 2),
    ] {
        let out = h.sniff(&args);
        assert_eq!(
            out.status.code(),
            Some(code),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let (code, v) = h.json(&["list", "--json", "--language", "pt"]);
    assert_eq!(code, 2);
    assert_eq!(v["error"], "Nenhuma análise salva. Rode sniff scan primeiro.");
    let out = h.sniff(&["--help", "--language", "es"]);
    assert!(String::from_utf8_lossy(&out.stdout).contains("COMANDOS"));
}

#[test]
fn foreign_home_and_expired_plans_are_rejected() {
    let h = home("foreign");
    h.write(".npm/_cacache/a", "x");
    h.json(&["scan", "--quick", "--json"]);
    let plan = h.root.join("p.json");
    h.json(&[
        "plan",
        "--category",
        "npm",
        "--output",
        plan.to_str().unwrap(),
        "--json",
    ]);
    let mut doc: Value = serde_json::from_slice(&fs::read(&plan).unwrap()).unwrap();
    doc["home"] = Value::String("/home/someone-else".into());
    let forged = h.root.join("forged.json");
    fs::write(&forged, serde_json::to_vec(&doc).unwrap()).unwrap();
    let (code, _) = h.json(&["clean", "--plan", forged.to_str().unwrap(), "--yes", "--json"]);
    assert_eq!(code, 2);
    let mut doc: Value = serde_json::from_slice(&fs::read(&plan).unwrap()).unwrap();
    doc["scanned_at"] = Value::from(doc["scanned_at"].as_i64().unwrap() - 901);
    let expired = h.root.join("expired.json");
    fs::write(&expired, serde_json::to_vec(&doc).unwrap()).unwrap();
    let (code, _) = h.json(&["clean", "--plan", expired.to_str().unwrap(), "--yes", "--json"]);
    assert_eq!(code, 2);
    assert!(h.home.join(".npm/_cacache/a").exists());
}

#[test]
fn state_stays_small_and_plans_reattach_manifests() {
    let h = home("slimstate");
    for i in 0..300 {
        h.write(&format!(".npm/_cacache/content/{i}"), "x");
    }
    h.json(&["scan", "--quick", "--json"]);
    let state = fs::read_to_string(h.home.join(".local/state/sniff/state.json")).unwrap();
    assert!(!state.contains("\"ino\""), "manifests must not be in state.json");
    assert!(h.home.join(".local/state/sniff/scan-manifests.json").exists());
    let plan = h.root.join("p.json");
    let (code, _) = h.json(&[
        "plan",
        "--category",
        "npm",
        "--output",
        plan.to_str().unwrap(),
        "--json",
    ]);
    assert_eq!(code, 0);
    let doc = fs::read_to_string(&plan).unwrap();
    assert!(doc.contains("\"ino\""), "plan carries the manifest");
    let (code, r) = h.json(&["clean", "--plan", plan.to_str().unwrap(), "--yes", "--json"]);
    assert_eq!(code, 0, "{r}");
}

/// Runs a script inside new user, mount and PID namespaces (no root needed)
/// so a bind mount can be placed inside a fixture cache.
fn in_namespace(h: &Home, script: &str) -> Option<Output> {
    let probe = Command::new("unshare")
        .args(["-rm", "--pid", "--fork", "--mount-proc", "true"])
        .status()
        .ok()?;
    if !probe.success() {
        eprintln!("skipping: unprivileged user namespaces unavailable");
        return None;
    }
    // The script runs from a file: a command line naming the cache path
    // would itself (correctly) mark the cache as in use.
    let file = h.root.join("ns-script.sh");
    fs::write(&file, script).unwrap();
    Some(
        Command::new("unshare")
            .args(["-rm", "--pid", "--fork", "--mount-proc", "sh", "-e"])
            .arg(&file)
            .env("SNIFF_HOME", &h.home)
            .env("SNIFF", env!("CARGO_BIN_EXE_sniff"))
            .env("LANG", "en_US.UTF-8")
            .output()
            .unwrap(),
    )
}

#[test]
fn bind_mounts_inside_candidates_are_never_traversed() {
    let h = home("bindmount");
    h.write(".npm/_cacache/a", "x");
    fs::create_dir_all(h.home.join(".npm/_cacache/inner")).unwrap();
    let precious = h.root.join("outside/precious.txt");
    fs::create_dir_all(precious.parent().unwrap()).unwrap();
    fs::write(&precious, "keep").unwrap();
    let cache = h.home.join(".npm/_cacache");
    let plan = h.root.join("p.json");
    let report = h.root.join("r.json");
    let scanout = h.root.join("s.json");
    // 1. Mounted before the scan: the item is not ready.
    // 2. Mounted after planning: cleanup keeps the item; nothing outside is touched.
    let script = format!(
        "mount --bind '{out}' '{inner}'\n\"$SNIFF\" scan --quick --json > '{scan}'\numount '{inner}'\n\
         \"$SNIFF\" scan --quick --json > /dev/null\n\"$SNIFF\" plan --category npm --output '{plan}' --json > /dev/null\n\
         mount --bind '{out}' '{inner}'\n\"$SNIFF\" clean --plan '{plan}' --yes --json > '{report}' || true\n",
        out = precious.parent().unwrap().display(),
        inner = cache.join("inner").display(),
        scan = scanout.display(),
        plan = plan.display(),
        report = report.display(),
    );
    let Some(out) = in_namespace(&h, &script) else { return };
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let scan: Value = serde_json::from_slice(&fs::read(&scanout).unwrap()).unwrap();
    let npm = scan["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["category"] == "npm")
        .unwrap();
    assert_ne!(npm["state"], "ready", "{npm}");
    let r: Value = serde_json::from_slice(&fs::read(&report).unwrap()).unwrap();
    assert_eq!(r["outcomes"][0]["removed"], false, "{r}");
    assert_eq!(fs::read_to_string(&precious).unwrap(), "keep");
    assert!(cache.join("a").exists());
}
