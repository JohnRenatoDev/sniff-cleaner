//! Data model shared by the scanner, planner, executor, CLI and plugin.

use crate::fsx::Manifest;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// A message stored by key and arguments, rendered in the reader's language
/// at display time. Persisted state never contains translated text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Msg {
    pub k: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub a: Vec<MsgArg>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum MsgArg {
    Text(String),
    Msg(Msg),
}

impl Msg {
    pub fn new(k: &str) -> Self {
        Msg {
            k: k.to_string(),
            a: Vec::new(),
        }
    }
    pub fn arg(mut self, v: impl ToString) -> Self {
        self.a.push(MsgArg::Text(v.to_string()));
        self
    }
    pub fn nested(mut self, m: Msg) -> Self {
        self.a.push(MsgArg::Msg(m));
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Category {
    Npm,
    Npx,
    Uv,
    Bun,
    Pnpm,
    Pip,
    NodeGyp,
    Go,
    Typescript,
    Nuget,
    Cargo,
    Gradle,
    RuntimeInstalls,
    Logs,
    Build,
    Worktree,
    Docker,
}

impl Category {
    pub const ALL: [Category; 17] = [
        Category::Npm,
        Category::Npx,
        Category::Uv,
        Category::Bun,
        Category::Pnpm,
        Category::Pip,
        Category::NodeGyp,
        Category::Go,
        Category::Typescript,
        Category::Nuget,
        Category::Cargo,
        Category::Gradle,
        Category::RuntimeInstalls,
        Category::Logs,
        Category::Build,
        Category::Worktree,
        Category::Docker,
    ];

    pub fn cli_name(self) -> &'static str {
        match self {
            Category::Npm => "npm",
            Category::Npx => "npx",
            Category::Uv => "uv",
            Category::Bun => "bun",
            Category::Pnpm => "pnpm",
            Category::Pip => "pip",
            Category::NodeGyp => "node-gyp",
            Category::Go => "go",
            Category::Typescript => "typescript",
            Category::Nuget => "nuget",
            Category::Cargo => "cargo",
            Category::Gradle => "gradle",
            Category::RuntimeInstalls => "runtime-installs",
            Category::Logs => "logs",
            Category::Build => "build",
            Category::Worktree => "worktree",
            Category::Docker => "docker",
        }
    }

    pub fn parse(s: &str) -> Option<Category> {
        let s = s.trim().to_ascii_lowercase();
        let alias = match s.as_str() {
            "nodegyp" => "node-gyp",
            "runtimeinstall" | "runtime-install" => "runtime-installs",
            other => other,
        };
        Category::ALL.into_iter().find(|c| c.cli_name() == alias)
    }

    /// Categories that may ever be cleaned by the scheduler.
    pub fn allows_automatic(self) -> bool {
        !matches!(
            self,
            Category::Npx | Category::Logs | Category::Build | Category::Worktree | Category::Docker
        )
    }

    pub fn inspection_only(self) -> bool {
        matches!(self, Category::Docker)
    }

    pub fn title_key(self) -> String {
        format!("category.{}", self.cli_name())
    }

    pub fn default_enabled() -> BTreeSet<Category> {
        Category::ALL.into_iter().filter(|c| c.allows_automatic()).collect()
    }
}

/// macOS categories of the original app with no Linux rule.
pub const NOT_ON_LINUX: &[&str] = &["swiftpm", "homebrew", "installer", "claude-vm", "signing-copies"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FindingState {
    Ready,
    InUse,
    Protected,
    Review,
    Inaccessible,
}

impl FindingState {
    pub fn raw(self) -> &'static str {
        match self {
            FindingState::Ready => "ready",
            FindingState::InUse => "in_use",
            FindingState::Protected => "protected",
            FindingState::Review => "review",
            FindingState::Inaccessible => "inaccessible",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorktreeStatus {
    Idle,
    InUse,
    LocalChanges,
    PendingCommits,
    LocalData,
    Locked,
    Recent,
    Excluded,
    Missing,
    Unverified,
}

impl WorktreeStatus {
    pub fn raw(self) -> &'static str {
        match self {
            WorktreeStatus::Idle => "idle",
            WorktreeStatus::InUse => "in_use",
            WorktreeStatus::LocalChanges => "local_changes",
            WorktreeStatus::PendingCommits => "pending_commits",
            WorktreeStatus::LocalData => "local_data",
            WorktreeStatus::Locked => "locked",
            WorktreeStatus::Recent => "recent",
            WorktreeStatus::Excluded => "excluded",
            WorktreeStatus::Missing => "missing",
            WorktreeStatus::Unverified => "unverified",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeRemovalContext {
    pub repository: String,
    pub common_directory: String,
    pub administrative_directory: String,
    pub head: String,
    pub branch: Option<String>,
    pub integration_reference: String,
    pub integration_head: String,
    pub remote_references: Vec<String>,
    pub administrative_manifest: Manifest,
}

impl PartialEq for Manifest {
    fn eq(&self, other: &Self) -> bool {
        self.partial == other.partial && self.mount_id == other.mount_id && self.entries == other.entries
    }
}
impl Eq for Manifest {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeAssessment {
    pub status: WorktreeStatus,
    pub repository: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comparison_reference: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_changes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unpublished_commits: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unmerged_commits: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignored_paths: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removal_context: Option<WorktreeRemovalContext>,
}

impl WorktreeAssessment {
    pub fn has_pending(&self) -> bool {
        self.local_changes.unwrap_or(0) > 0
            || self.unpublished_commits.unwrap_or(0) > 0
            || self.unmerged_commits.unwrap_or(0) > 0
            || matches!(
                self.status,
                WorktreeStatus::PendingCommits
                    | WorktreeStatus::LocalChanges
                    | WorktreeStatus::LocalData
                    | WorktreeStatus::Locked
            )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Finding {
    pub path: String,
    pub title: Msg,
    pub category: Category,
    pub rule_id: String,
    pub state: FindingState,
    pub reason: Msg,
    pub logical_bytes: u64,
    pub allocated_bytes: u64,
    /// Allocated bytes not shared with files outside the item: the space
    /// removal is expected to free.
    #[serde(default)]
    pub exclusive_bytes: u64,
    /// Files with more than one hardlink; removal may free less space.
    pub shared_links: bool,
    /// Sizes are a lower bound; the walk stopped early.
    pub partial_measurement: bool,
    #[serde(default)]
    pub details: Vec<Msg>,
    #[serde(default)]
    pub manifest: Manifest,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<WorktreeAssessment>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanSnapshot {
    pub date: i64,
    pub home: String,
    pub mode: ScanMode,
    pub findings: Vec<Finding>,
    pub notices: Vec<Msg>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanMode {
    Quick,
    Full,
    Worktrees,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemovalOutcome {
    pub path: String,
    pub removed: bool,
    #[serde(default)]
    pub partially_removed: bool,
    pub message: Msg,
    pub allocated_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CleaningReport {
    pub date: i64,
    pub automatic: bool,
    pub outcomes: Vec<RemovalOutcome>,
    pub available_before: Option<u64>,
    pub available_after: Option<u64>,
}

impl CleaningReport {
    pub fn net_change(&self) -> Option<i64> {
        Some(self.available_after? as i64 - self.available_before? as i64)
    }
    pub fn removed_allocated(&self) -> u64 {
        self.outcomes
            .iter()
            .filter(|o| o.removed || o.partially_removed)
            .map(|o| o.allocated_bytes)
            .sum()
    }
    pub fn all_removed(&self) -> bool {
        self.outcomes.iter().all(|o| o.removed)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScheduleMode {
    Analyze,
    Automatic,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preferences {
    pub enabled_categories: BTreeSet<Category>,
    pub exclusions: Vec<String>,
    pub project_roots: Vec<String>,
    pub retention_days: u32,
    pub log_retention_days: u32,
    pub schedule_enabled: bool,
    pub schedule_mode: ScheduleMode,
    pub interval_hours: u32,
    /// `en`, `pt`, `es` or `system`.
    pub language: String,
}

impl Default for Preferences {
    fn default() -> Self {
        Preferences {
            enabled_categories: Category::default_enabled(),
            exclusions: Vec::new(),
            project_roots: Vec::new(),
            retention_days: 14,
            log_retention_days: 30,
            schedule_enabled: false,
            schedule_mode: ScheduleMode::Analyze,
            interval_hours: 24,
            language: "system".to_string(),
        }
    }
}

/// Mutable state written by scans, cleanups and the scheduler.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PersistedState {
    pub schema_version: u32,
    #[serde(default)]
    pub last_scan: Option<ScanSnapshot>,
    #[serde(default)]
    pub history: Vec<CleaningReport>,
    #[serde(default)]
    pub next_run: Option<i64>,
    #[serde(default)]
    pub scheduler_last_wake: Option<i64>,
    #[serde(default)]
    pub scheduler_message: Option<Msg>,
}

pub const HISTORY_LIMIT: usize = 30;
pub const PLAN_TTL_SECS: i64 = 900;
pub const CLOCK_SKEW_SECS: i64 = 30;
