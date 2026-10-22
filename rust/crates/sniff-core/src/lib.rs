//! Sniff core for Linux: deterministic, local cleanup rules for caches and
//! leftovers of AI agents and development tools. No network or model calls.

pub mod catalog;
pub mod command;
pub mod executor;
pub mod fsx;
pub mod i18n;
pub mod model;
pub mod paths;
pub mod plan;
pub mod procs;
pub mod scanner;
pub mod schedule;
pub mod store;
pub mod worktree;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
