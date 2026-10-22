//! Reviewable cleanup plans: selection from the saved scan, and plan files
//! written once (never overwritten) with mode 0600.

use crate::model::*;
use crate::paths::{canonical, expand_tilde};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

pub const PLAN_MAX_BYTES: u64 = 64 * 1024 * 1024;

/// A failure with a user-facing message and a CLI exit code.
#[derive(Debug, Clone)]
pub struct Failure {
    pub msg: Msg,
    pub code: i32,
}

impl Failure {
    pub fn usage(msg: Msg) -> Self {
        Failure { msg, code: 2 }
    }
    pub fn runtime(msg: Msg) -> Self {
        Failure { msg, code: 1 }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanDocument {
    pub schema_version: u32,
    pub home: String,
    pub scanned_at: i64,
    pub created_at: i64,
    pub findings: Vec<Finding>,
}

pub fn within_window(scanned_at: i64, now: i64) -> bool {
    let age = now - scanned_at;
    (-CLOCK_SKEW_SECS..PLAN_TTL_SECS).contains(&age)
}

/// Picks plan items from the saved scan. Without filters only categories
/// that allow automatic cleanup are selected; manual categories (worktrees,
/// npx, logs, builds) need an explicit `--category` or `--path`.
pub fn select(
    scan: Option<&ScanSnapshot>,
    prefs: &Preferences,
    categories: &[Category],
    paths: &[String],
    home: &Path,
    now: i64,
) -> Result<Vec<Finding>, Failure> {
    let scan = scan.ok_or_else(|| Failure::usage(Msg::new("cli.no_scan")))?;
    let mut items: Vec<&Finding> = scan.findings.iter().collect();
    if !categories.is_empty() {
        items.retain(|f| categories.contains(&f.category));
    }
    if !paths.is_empty() {
        let wanted: Vec<String> = paths
            .iter()
            .map(|p| crate::paths::to_string(&canonical(&expand_tilde(p, home))))
            .collect();
        for (raw, w) in paths.iter().zip(&wanted) {
            if !scan.findings.iter().any(|f| &f.path == w) {
                return Err(Failure::usage(Msg::new("cli.path_not_in_scan").arg(raw)));
            }
        }
        items.retain(|f| wanted.contains(&f.path));
    }
    items.retain(|f| f.state == FindingState::Ready && prefs.enabled_categories.contains(&f.category));
    if categories.is_empty() && paths.is_empty() {
        items.retain(|f| f.category.allows_automatic());
    }
    if items.is_empty() {
        return Err(Failure::usage(Msg::new("cli.no_eligible")));
    }
    if !within_window(scan.date, now) {
        return Err(Failure::usage(Msg::new("cli.plan_expired")));
    }
    Ok(items.into_iter().cloned().collect())
}

pub fn write_plan(path: &Path, doc: &PlanDocument) -> Result<(), Failure> {
    let data = serde_json::to_vec_pretty(doc).map_err(|_| Failure::runtime(Msg::new("cli.plan_too_large")))?;
    if data.len() as u64 > PLAN_MAX_BYTES {
        return Err(Failure::usage(Msg::new("cli.plan_too_large")));
    }
    let cannot = || Failure::usage(Msg::new("cli.plan_cannot_create").arg(path.display()));
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(path)
        .map_err(|_| cannot())?;
    if f.write_all(&data)
        .and_then(|_| f.write_all(b"\n"))
        .and_then(|_| f.sync_all())
        .is_err()
    {
        drop(f);
        let _ = std::fs::remove_file(path);
        return Err(cannot());
    }
    Ok(())
}

pub fn read_plan(path: &Path, home: &Path, now: i64) -> Result<PlanDocument, Failure> {
    let invalid = || Failure::usage(Msg::new("cli.plan_invalid"));
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(path)
        .map_err(|_| invalid())?;
    let meta = f.metadata().map_err(|_| invalid())?;
    if !meta.is_file() || meta.len() > PLAN_MAX_BYTES {
        return Err(invalid());
    }
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).map_err(|_| invalid())?;
    let doc: PlanDocument = serde_json::from_slice(&buf).map_err(|_| invalid())?;
    if doc.schema_version != 1 || doc.home != crate::paths::to_string(home) || doc.findings.is_empty() {
        return Err(Failure::usage(Msg::new("cli.plan_foreign")));
    }
    if !within_window(doc.scanned_at, now) {
        return Err(Failure::usage(Msg::new("cli.plan_expired")));
    }
    let mut seen = HashSet::new();
    if !doc.findings.iter().all(|f| seen.insert(f.path.clone())) {
        return Err(Failure::usage(Msg::new("cli.plan_duplicates")));
    }
    Ok(doc)
}
