#![allow(dead_code)]
//! Fixture helpers. Every test works in its own temporary directory; nothing
//! touches the real home.

use sniff_core::catalog::{Catalog, ToolEnv};
use sniff_core::executor::Executor;
use sniff_core::model::*;
use sniff_core::procs::ProcessInventory;
use sniff_core::scanner::Scanner;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

pub struct Fixture {
    pub root: PathBuf,
    pub home: PathBuf,
    pub prefs: Preferences,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // Make everything writable again so cleanup of the fixture succeeds.
        let _ = Command::new("chmod").args(["-R", "u+rwX"]).arg(&self.root).status();
        let _ = fs::remove_dir_all(&self.root);
    }
}

impl Fixture {
    pub fn new(name: &str) -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!("sniff-tests-{}-{}-{n}", name, std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        let home = root.join("home");
        fs::create_dir_all(&home).unwrap();
        Fixture {
            root,
            home,
            prefs: Preferences::default(),
        }
    }

    pub fn catalog(&self) -> Catalog {
        Catalog::new(&self.home, &ToolEnv::empty())
    }

    pub fn write(&self, rel: &str, content: &str) -> PathBuf {
        let p = self.home.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, content).unwrap();
        p
    }

    pub fn scan_with(&self, inv: &ProcessInventory, mode: ScanMode) -> ScanSnapshot {
        let cat = self.catalog();
        let progress = |_m: Msg| {};
        let s = Scanner::new(&cat, &self.prefs, inv, &progress);
        s.scan(mode)
    }

    pub fn scan(&self) -> ScanSnapshot {
        self.scan_with(&ProcessInventory::empty_complete(), ScanMode::Full)
    }

    pub fn finding(&self, scan: &ScanSnapshot, path: &Path) -> Finding {
        scan.findings
            .iter()
            .find(|f| Path::new(&f.path) == path)
            .unwrap_or_else(|| {
                panic!(
                    "no finding for {}: {:?}",
                    path.display(),
                    scan.findings.iter().map(|f| &f.path).collect::<Vec<_>>()
                )
            })
            .clone()
    }

    /// Runs the executor with an injected usage probe and pre-unlink hook.
    pub fn clean_with(
        &self,
        items: &[Finding],
        scanned_at: i64,
        automatic: bool,
        use_check: &mut dyn FnMut(&Finding) -> Option<Msg>,
        hook: &mut dyn FnMut(&str),
    ) -> CleaningReport {
        let cat = self.catalog();
        let clock = sniff_core::store::now_secs;
        let mut ex = Executor {
            catalog: &cat,
            prefs: &self.prefs,
            automatic,
            use_check,
            before_unlink: hook,
            now: &clock,
        };
        ex.execute(items, scanned_at)
    }

    pub fn clean(&self, items: &[Finding], scanned_at: i64) -> CleaningReport {
        self.clean_with(items, scanned_at, false, &mut |_| None, &mut |_| {})
    }
}

/// Sets atime and mtime of every entry under `path` (without following
/// symlinks) to `days` ago.
pub fn age(path: &Path, days: i64) {
    let secs = sniff_core::store::now_secs() - days * 86_400;
    let stamp = format!("@{secs}");
    let st = Command::new("touch")
        .args(["-h", "-d", &stamp])
        .arg(path)
        .status()
        .unwrap();
    assert!(st.success());
    let st = Command::new("find")
        .arg(path)
        .args(["-exec", "touch", "-h", "-d", &stamp, "{}", "+"])
        .status()
        .unwrap();
    assert!(st.success());
}

pub fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("/usr/bin/git")
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "init.defaultBranch=trunk-real",
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
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim_end().to_string()
}

pub fn removed(r: &CleaningReport, p: &Path) -> bool {
    r.outcomes.iter().any(|o| Path::new(&o.path) == p && o.removed)
}

pub fn outcome<'a>(r: &'a CleaningReport, p: &Path) -> &'a RemovalOutcome {
    r.outcomes.iter().find(|o| Path::new(&o.path) == p).expect("outcome")
}
