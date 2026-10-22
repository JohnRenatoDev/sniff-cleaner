//! Linux rule catalog: where each recognized cache lives, how its targets are
//! laid out, which processes indicate active use, and which paths are always
//! protected. Paths come from the tools' documented environment variables
//! and XDG defaults; tool configuration files are not executed or parsed.

use crate::model::{Category, Finding, Msg};
use crate::paths::{canonical, contains};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Layout {
    /// The base directory itself is one candidate.
    Whole,
    /// Each direct child whose name starts with the prefix is a candidate.
    Children(&'static str),
    /// Each file under the base with one of the extensions is a candidate,
    /// optionally only inside directories whose name starts with a prefix.
    Logs {
        extensions: &'static [&'static str],
        dir_prefix: Option<&'static str>,
    },
}

#[derive(Debug, Clone)]
pub struct Rule {
    pub id: &'static str,
    pub category: Category,
    pub base: PathBuf,
    pub layout: Layout,
    /// Command-line fragments that mean the tool is active.
    pub tokens: &'static [&'static str],
    /// Where the path came from, for documentation and `sniff categories --json`.
    pub source: String,
}

impl Rule {
    pub fn matches(&self, path: &Path) -> bool {
        match &self.layout {
            Layout::Whole => path == self.base,
            Layout::Children(prefix) => {
                path.parent() == Some(self.base.as_path())
                    && path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with(prefix))
            }
            Layout::Logs { extensions, dir_prefix } => {
                if !contains(&self.base, path) || path == self.base {
                    return false;
                }
                let ext_ok = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .is_some_and(|e| extensions.contains(&e));
                let dir_ok = match dir_prefix {
                    None => true,
                    Some(p) => path
                        .parent()
                        .and_then(|d| d.file_name())
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with(p)),
                };
                ext_ok && dir_ok
            }
        }
    }
}

/// Environment used to resolve tool paths. Tests pass an explicit map so a
/// fixture home is never mixed with the real user's variables.
#[derive(Debug, Clone, Default)]
pub struct ToolEnv {
    vars: HashMap<String, String>,
}

impl ToolEnv {
    pub fn from_process() -> Self {
        let names = [
            "npm_config_cache",
            "NPM_CONFIG_CACHE",
            "XDG_CACHE_HOME",
            "XDG_DATA_HOME",
            "UV_CACHE_DIR",
            "PIP_CACHE_DIR",
            "BUN_INSTALL_CACHE_DIR",
            "BUN_INSTALL",
            "GOCACHE",
            "CARGO_HOME",
            "GRADLE_USER_HOME",
            "NUGET_HTTP_CACHE_PATH",
        ];
        let vars = names
            .iter()
            .filter_map(|n| {
                std::env::var(n)
                    .ok()
                    .filter(|v| v.starts_with('/'))
                    .map(|v| (n.to_string(), v))
            })
            .collect();
        ToolEnv { vars }
    }

    pub fn empty() -> Self {
        ToolEnv::default()
    }

    pub fn with(mut self, k: &str, v: &str) -> Self {
        self.vars.insert(k.to_string(), v.to_string());
        self
    }

    fn get(&self, k: &str) -> Option<PathBuf> {
        self.vars.get(k).map(PathBuf::from)
    }
}

/// Relative paths under home that are never cleanup candidates.
pub const PROTECTED_RELATIVE: &[&str] = &[
    ".codex/sessions",
    ".codex/sqlite",
    ".codex/auth.json",
    ".codex/config.toml",
    ".claude",
    ".claude.json",
    ".ssh",
    ".aws",
    ".gnupg",
    ".config",
    ".local/state/sniff",
    ".cache/codex-runtimes/codex-primary-runtime",
];

pub const BUILD_TOKENS: &[&str] = &["cargo build", "cargo test", "rustc", "swift-frontend", "swift build"];

/// Command fragments that mean a build is in progress (scheduler deferral).
pub const BUILD_IN_PROGRESS: &[&str] = &[
    "swift-frontend",
    "rustc",
    "cargo build",
    "cargo test",
    "ninja ",
    "clang -",
    "gcc -",
    "GradleDaemon",
    "dotnet build",
    "go build",
    "tsc --build",
];

#[derive(Debug, Clone)]
pub struct Catalog {
    pub home: PathBuf,
    pub rules: Vec<Rule>,
    pub agent_worktree_roots: Vec<PathBuf>,
}

impl Catalog {
    pub fn new(home: &Path, env: &ToolEnv) -> Self {
        let home = canonical(home);
        let cache_home = env.get("XDG_CACHE_HOME").unwrap_or_else(|| home.join(".cache"));
        let data_home = env.get("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share"));
        let src = |var: &str, default: &str| -> String {
            if env.get(var).is_some() {
                format!("${var}")
            } else {
                default.to_string()
            }
        };

        let npm_cache = env
            .get("npm_config_cache")
            .or_else(|| env.get("NPM_CONFIG_CACHE"))
            .unwrap_or_else(|| home.join(".npm"));
        let npm_src = src("npm_config_cache", "~/.npm");
        let uv = env.get("UV_CACHE_DIR").unwrap_or_else(|| cache_home.join("uv"));
        let pip = env.get("PIP_CACHE_DIR").unwrap_or_else(|| cache_home.join("pip"));
        let bun = env
            .get("BUN_INSTALL_CACHE_DIR")
            .or_else(|| env.get("BUN_INSTALL").map(|b| b.join("install/cache")))
            .unwrap_or_else(|| home.join(".bun/install/cache"));
        let go = env.get("GOCACHE").unwrap_or_else(|| cache_home.join("go-build"));
        let cargo_home = env.get("CARGO_HOME").unwrap_or_else(|| home.join(".cargo"));
        let gradle_home = env.get("GRADLE_USER_HOME").unwrap_or_else(|| home.join(".gradle"));
        let nuget = env
            .get("NUGET_HTTP_CACHE_PATH")
            .unwrap_or_else(|| home.join(".local/share/NuGet/http-cache"));

        let rules = vec![
            Rule {
                id: "npm",
                category: Category::Npm,
                base: npm_cache.join("_cacache"),
                layout: Layout::Whole,
                tokens: &["npm install", "npm ci", "npm exec", "npm cache"],
                source: format!("{npm_src}/_cacache"),
            },
            Rule {
                id: "npx",
                category: Category::Npx,
                base: npm_cache.join("_npx"),
                layout: Layout::Children(""),
                tokens: &["npx ", "npm exec"],
                source: format!("{npm_src}/_npx/*"),
            },
            Rule {
                id: "uv",
                category: Category::Uv,
                base: uv,
                layout: Layout::Whole,
                tokens: &["uv sync", "uv pip", "uv tool", "uv cache", "uv run", "uvx "],
                source: src("UV_CACHE_DIR", "$XDG_CACHE_HOME/uv"),
            },
            Rule {
                id: "bun",
                category: Category::Bun,
                base: bun,
                layout: Layout::Whole,
                tokens: &["bun install", "bun add"],
                source: src("BUN_INSTALL_CACHE_DIR", "~/.bun/install/cache"),
            },
            Rule {
                id: "pnpm-cache",
                category: Category::Pnpm,
                base: cache_home.join("pnpm"),
                layout: Layout::Whole,
                tokens: &["pnpm install", "pnpm add", "pnpm i"],
                source: "$XDG_CACHE_HOME/pnpm".into(),
            },
            Rule {
                id: "pnpm-store",
                category: Category::Pnpm,
                base: data_home.join("pnpm/store"),
                layout: Layout::Children(""),
                tokens: &["pnpm install", "pnpm add", "pnpm i"],
                source: "$XDG_DATA_HOME/pnpm/store/*".into(),
            },
            Rule {
                id: "pip",
                category: Category::Pip,
                base: pip,
                layout: Layout::Whole,
                tokens: &["pip install", "pip3 install"],
                source: src("PIP_CACHE_DIR", "$XDG_CACHE_HOME/pip"),
            },
            Rule {
                id: "node-gyp",
                category: Category::NodeGyp,
                base: cache_home.join("node-gyp"),
                layout: Layout::Whole,
                tokens: &["node-gyp", "npm install", "npm ci"],
                source: "$XDG_CACHE_HOME/node-gyp".into(),
            },
            Rule {
                id: "go",
                category: Category::Go,
                base: go,
                layout: Layout::Whole,
                tokens: &["go build", "go test", "go run", "go vet"],
                source: src("GOCACHE", "$XDG_CACHE_HOME/go-build"),
            },
            Rule {
                id: "typescript",
                category: Category::Typescript,
                base: cache_home.join("typescript"),
                layout: Layout::Whole,
                tokens: &["tsserver", "typingsInstaller"],
                source: "$XDG_CACHE_HOME/typescript".into(),
            },
            Rule {
                id: "nuget",
                category: Category::Nuget,
                base: nuget,
                layout: Layout::Whole,
                tokens: &["dotnet restore", "dotnet build", "nuget"],
                source: src("NUGET_HTTP_CACHE_PATH", "~/.local/share/NuGet/http-cache"),
            },
            Rule {
                id: "cargo-cache",
                category: Category::Cargo,
                base: cargo_home.join("registry/cache"),
                layout: Layout::Whole,
                tokens: &[
                    "cargo build",
                    "cargo test",
                    "cargo fetch",
                    "cargo check",
                    "cargo install",
                    "rustc",
                ],
                source: format!("{}/registry/cache", src("CARGO_HOME", "~/.cargo")),
            },
            Rule {
                id: "gradle",
                category: Category::Gradle,
                base: gradle_home.join("caches"),
                layout: Layout::Children(""),
                tokens: &["gradle", "GradleDaemon"],
                source: format!("{}/caches/*", src("GRADLE_USER_HOME", "~/.gradle")),
            },
            Rule {
                id: "codex-install",
                category: Category::RuntimeInstalls,
                base: cache_home.join("codex-runtimes"),
                layout: Layout::Children("codex-runtime-install-"),
                tokens: &["codex-runtime-install"],
                source: "$XDG_CACHE_HOME/codex-runtimes/codex-runtime-install-*".into(),
            },
            Rule {
                id: "codex-log",
                category: Category::Logs,
                base: home.join(".codex/log"),
                layout: Layout::Logs {
                    extensions: &["log"],
                    dir_prefix: None,
                },
                tokens: &[],
                source: "~/.codex/log/**/*.log".into(),
            },
            Rule {
                id: "claude-mcp-log",
                category: Category::Logs,
                base: cache_home.join("claude-cli-nodejs"),
                layout: Layout::Logs {
                    extensions: &["jsonl", "log", "txt"],
                    dir_prefix: Some("mcp-logs-"),
                },
                tokens: &[],
                source: "$XDG_CACHE_HOME/claude-cli-nodejs/*/mcp-logs-*/*".into(),
            },
        ];
        // Bases are not canonicalized: a symlinked cache folder must be
        // reported as a symlink, never resolved into a different target.
        let agent_worktree_roots = vec![home.join(".codex/worktrees"), home.join(".claude/worktrees")];
        Catalog {
            home,
            rules,
            agent_worktree_roots,
        }
    }

    pub fn rule(&self, id: &str) -> Option<&Rule> {
        self.rules.iter().find(|r| r.id == id)
    }

    /// Reason a path is protected, if it is.
    pub fn protected_reason(&self, path: &Path, exclusions: &[String], repository: Option<&Path>) -> Option<Msg> {
        for rel in PROTECTED_RELATIVE {
            let p = self.home.join(rel);
            if contains(&p, path) {
                return Some(Msg::new("reason.protected_path"));
            }
        }
        for ex in exclusions {
            let e = canonical(Path::new(ex));
            if contains(&e, path) || contains(path, &e) || repository.is_some_and(|r| contains(&e, r)) {
                return Some(Msg::new("reason.excluded").arg(ex));
            }
        }
        None
    }

    /// Whether a finding names a target that a recognized rule produces.
    pub fn validates(&self, f: &Finding, project_roots: &[PathBuf]) -> bool {
        let path = Path::new(&f.path);
        match f.rule_id.as_str() {
            "rust-target" | "swift-build" => {
                let (name, marker) = if f.rule_id == "rust-target" {
                    ("target", "Cargo.toml")
                } else {
                    (".build", "Package.swift")
                };
                let Some(parent) = path.parent() else { return false };
                f.category == Category::Build
                    && path.file_name().and_then(|n| n.to_str()) == Some(name)
                    && crate::fsx::lstat_nofollow(&parent.join(marker))
                        .is_ok_and(|st| crate::fsx::EntryKind::from_stat(&st) == crate::fsx::EntryKind::File)
                    && project_roots.iter().any(|r| contains(r, parent))
            }
            id => self
                .rule(id)
                .is_some_and(|r| r.category == f.category && r.matches(path)),
        }
    }
}
