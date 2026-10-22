//! Executes a reviewed plan. Every item is revalidated immediately before
//! removal: plan age, rule, category permission, exclusions, manifest,
//! retention, process usage, Git state for worktrees, then the manifest once
//! more after the usage check. Any doubt keeps the item.

use crate::catalog::{Catalog, BUILD_TOKENS};
use crate::fsx::{self, EntryKind, Manifest};
use crate::model::*;
use crate::paths::{contains, to_string};
use crate::plan::within_window;
use crate::procs::ProcessInventory;
use crate::scanner::{measure, npx_must_preserve, project_roots, retention_reason, MANIFEST_LIMIT};
use crate::worktree::{remove_worktree, stop_msg, WorktreeInspector, WorktreeRemovalError};
use std::path::{Path, PathBuf};

pub struct Executor<'a> {
    pub catalog: &'a Catalog,
    pub prefs: &'a Preferences,
    pub automatic: bool,
    /// Fresh process probe for one item. Production captures `/proc`.
    pub use_check: &'a mut dyn FnMut(&Finding) -> Option<Msg>,
    /// Called right before each unlink (tests simulate late writers).
    pub before_unlink: &'a mut dyn FnMut(&str),
    pub now: &'a dyn Fn() -> i64,
}

/// Production usage probe: a new `/proc` capture per item.
pub fn default_use_check(catalog: &Catalog) -> impl FnMut(&Finding) -> Option<Msg> + '_ {
    move |f: &Finding| {
        let inv = ProcessInventory::capture();
        let tokens: &[&str] = match catalog.rule(&f.rule_id) {
            Some(r) => r.tokens,
            None if f.category == Category::Worktree => &[],
            None => BUILD_TOKENS,
        };
        inv.reason(Path::new(&f.path), tokens, Some(&f.manifest))
    }
}

fn kept(f: &Finding, msg: Msg) -> RemovalOutcome {
    RemovalOutcome {
        path: f.path.clone(),
        removed: false,
        partially_removed: false,
        message: msg,
        allocated_bytes: 0,
    }
}

impl Executor<'_> {
    pub fn execute(&mut self, findings: &[Finding], scanned_at: i64) -> CleaningReport {
        let home = self.catalog.home.clone();
        let available_before = fsx::available_bytes(&home);
        let mut accepted: Vec<PathBuf> = Vec::new();
        let mut outcomes = Vec::new();
        for f in findings {
            outcomes.push(match self.check(f, scanned_at, &accepted) {
                Err(msg) => kept(f, msg),
                Ok(()) => {
                    accepted.push(PathBuf::from(&f.path));
                    self.remove(f)
                }
            });
        }
        CleaningReport {
            date: (self.now)(),
            automatic: self.automatic,
            outcomes,
            available_before,
            available_after: fsx::available_bytes(&home),
        }
    }

    fn check(&mut self, f: &Finding, scanned_at: i64, accepted: &[PathBuf]) -> Result<(), Msg> {
        let path = Path::new(&f.path);
        let roots = project_roots(self.prefs);
        if !within_window(scanned_at, (self.now)()) {
            return Err(Msg::new("exec.expired"));
        }
        let recognized = match f.category {
            Category::Worktree => self.inspector().recognizes(f),
            Category::Docker => false,
            _ => self.catalog.validates(f, &roots),
        };
        if f.state != FindingState::Ready || f.manifest.entries.is_empty() || !f.manifest.is_complete() || !recognized {
            return Err(Msg::new("exec.not_recognized"));
        }
        if !self.prefs.enabled_categories.contains(&f.category) || (self.automatic && !f.category.allows_automatic()) {
            return Err(Msg::new("exec.category_not_allowed"));
        }
        if accepted.iter().any(|a| contains(a, path) || contains(path, a)) {
            return Err(Msg::new("exec.duplicate"));
        }
        let repo = f.worktree.as_ref().map(|w| PathBuf::from(&w.repository));
        if let Some(reason) = self
            .catalog
            .protected_reason(path, &self.prefs.exclusions, repo.as_deref())
        {
            return Err(reason);
        }
        let current = self.current_manifest(f)?;
        if fsx::compare_manifests(&f.manifest, &current).is_some() {
            return Err(Msg::new("exec.content_changed"));
        }
        if f.category == Category::Npx && npx_must_preserve(path) {
            return Err(Msg::new("reason.npx_mcp"));
        }
        if retention_reason(f.category, &current, self.prefs, (self.now)()).is_some() {
            return Err(Msg::new("exec.retention"));
        }
        if let Some(reason) = (self.use_check)(f) {
            return Err(reason);
        }
        if f.category == Category::Worktree {
            self.inspector().revalidate(f)?;
        }
        let again = self.current_manifest(f)?;
        if fsx::compare_manifests(&f.manifest, &again).is_some() {
            return Err(Msg::new("exec.changed_during_check"));
        }
        Ok(())
    }

    fn inspector(&self) -> WorktreeInspector<'_> {
        // Process usage is covered by `use_check`; the inspector re-runs Git
        // and file checks only.
        static EMPTY: std::sync::OnceLock<ProcessInventory> = std::sync::OnceLock::new();
        WorktreeInspector::new(
            self.catalog,
            self.prefs,
            EMPTY.get_or_init(ProcessInventory::empty_complete),
            (self.now)(),
            MANIFEST_LIMIT,
        )
    }

    fn current_manifest(&self, f: &Finding) -> Result<Manifest, Msg> {
        let m = measure(Path::new(&f.path), MANIFEST_LIMIT.max(f.manifest.entries.len() + 1))
            .map_err(|_| Msg::new("exec.content_changed"))?;
        if m.partial.is_some() {
            return Err(Msg::new("exec.content_changed"));
        }
        Ok(m)
    }

    fn remove(&mut self, f: &Finding) -> RemovalOutcome {
        let path = Path::new(&f.path);
        let root_kind = f.manifest.root().map(|r| r.id.kind);
        let result = if f.category == Category::Worktree {
            match remove_worktree(f, self.before_unlink) {
                Ok(r) => Ok(r),
                Err(WorktreeRemovalError::Kept(m)) => return kept(f, m),
                Err(WorktreeRemovalError::Partial(m, r)) => Err((m, r)),
            }
        } else if root_kind == Some(EntryKind::Dir) {
            let r = fsx::remove_manifest_with_hook(path, &f.manifest, None, self.before_unlink);
            if r.complete {
                Ok(r)
            } else {
                Err((stop_msg(r.stopped.as_ref()), r))
            }
        } else {
            remove_single(path, &f.manifest)
                .map(|_| fsx::RemovalReport::default())
                .map_err(|m| (m, fsx::RemovalReport::default()))
        };
        match result {
            Ok(_) => RemovalOutcome {
                path: f.path.clone(),
                removed: true,
                partially_removed: false,
                message: Msg::new("exec.removed"),
                allocated_bytes: f.manifest.allocated_bytes,
            },
            Err((m, r)) if r.removed_entries == 0 => kept(f, m),
            Err((m, r)) => RemovalOutcome {
                path: f.path.clone(),
                removed: false,
                partially_removed: true,
                message: Msg::new("exec.partial").nested(m),
                allocated_bytes: r.removed_allocated_bytes,
            },
        }
    }
}

/// Removes a single non-directory candidate (a log file).
fn remove_single(path: &Path, m: &Manifest) -> Result<(), Msg> {
    let Some(root) = m.root() else {
        return Err(Msg::new("exec.not_recognized"));
    };
    let (parent, name) = fsx::open_parent_nofollow(path).map_err(|_| Msg::new("removal.unreachable"))?;
    let st = rustix::fs::statat(&parent, name.as_c_str(), rustix::fs::AtFlags::SYMLINK_NOFOLLOW)
        .map_err(|_| Msg::new("removal.missing").arg(to_string(path)))?;
    if fsx::Identity::from_stat(&st) != root.id {
        return Err(Msg::new("removal.changed").arg(to_string(path)));
    }
    rustix::fs::unlinkat(&parent, name.as_c_str(), rustix::fs::AtFlags::empty())
        .map_err(|e| Msg::new("removal.failed").arg(to_string(path)).arg(e.raw_os_error()))
}

/// Applies a report to the saved state: history (newest first, bounded),
/// removed items dropped from the last scan, partial items marked preserved.
pub fn apply_report(state: &mut PersistedState, report: &CleaningReport) {
    state.history.insert(0, report.clone());
    state.history.truncate(HISTORY_LIMIT);
    if let Some(scan) = state.last_scan.as_mut() {
        for o in &report.outcomes {
            if o.removed {
                scan.findings.retain(|f| f.path != o.path);
            } else if o.partially_removed {
                if let Some(f) = scan.findings.iter_mut().find(|f| f.path == o.path) {
                    f.state = FindingState::Protected;
                    f.reason = o.message.clone();
                    f.manifest = Manifest::default();
                    f.partial_measurement = true;
                    f.allocated_bytes = f.allocated_bytes.saturating_sub(o.allocated_bytes);
                }
            }
        }
    }
}
