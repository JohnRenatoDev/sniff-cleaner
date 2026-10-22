# Sniff on Linux: cleaning policy

Sniff removes only targets produced by a rule in `rust/crates/sniff-core/src/catalog.rs`
or by the worktree inspector. A large, old or Git-ignored folder is never
enough on its own. Items start unselected; nothing is removed without a plan
the user reviewed and confirmed, or a scheduled run limited to the
regenerable categories the user enabled.

## Category equivalence

Paths are resolved from each tool's documented environment variable when it
is set to an absolute path, otherwise from the XDG defaults. Configuration
files (`.npmrc`, `pip.conf`, `config.toml`…) are not parsed and tools are not
executed to ask for their paths; a cache moved through such a file is simply
not found.

| Original rule (macOS) | Linux path recognized | Mode | Limitations |
| --- | --- | --- | --- |
| npm `~/.npm/_cacache` | `$npm_config_cache` or `~/.npm`, `/_cacache` | Automatic allowed | Kept while `npm install`, `i`, `ci`, `cache`, `update`, `rebuild`, `pack` or `publish` runs, or a process has a file in it open. Long-running `npm exec`/`npx` processes (MCP servers) no longer block it: once started they do not use the cache. If a new `npx` writes to the cache during removal, the manifest no longer matches and removal stops (partial, recorded). |
| npx `~/.npm/_npx/*` | same base, `/_npx/*` | Manual only | MCP environments, unreadable or symlinked lockfiles, active `npx` and items newer than the retention are preserved. |
| uv `~/.cache/uv` | `$UV_CACHE_DIR` or `$XDG_CACHE_HOME/uv` | Automatic allowed | Interpreters and tools in `~/.local/share/uv` are not touched. |
| Bun `~/.bun/install/cache` | `$BUN_INSTALL_CACHE_DIR`, `$BUN_INSTALL/install/cache` or `~/.bun/install/cache` | Automatic allowed | Not present on the test machine. |
| pnpm `Library/Caches/pnpm` | `$XDG_CACHE_HOME/pnpm` | Automatic allowed | — |
| pnpm `Library/pnpm/store/*` | `$XDG_DATA_HOME/pnpm/store/*` | Automatic allowed | Projects hardlink into the store; their files survive, and space shared with them is not freed (reported as external links). `store-dir` from `.npmrc` is not read. |
| pip `Library/Caches/pip`, `~/.cache/pip` | `$PIP_CACHE_DIR` or `$XDG_CACHE_HOME/pip` | Automatic allowed | — |
| node-gyp `Library/Caches/node-gyp` | `$XDG_CACHE_HOME/node-gyp` | Automatic allowed | Not present on the test machine. |
| Go `Library/Caches/go-build` | `$GOCACHE` or `$XDG_CACHE_HOME/go-build` | Automatic allowed | Module sources (`GOMODCACHE`) are preserved. Not present on the test machine. |
| TypeScript `Library/Caches/typescript` | `$XDG_CACHE_HOME/typescript` | Automatic allowed | Not present on the test machine. |
| NuGet `~/.local/share/NuGet/http-cache` | `$NUGET_HTTP_CACHE_PATH` or same path | Automatic allowed | Package folder `~/.nuget/packages` is preserved. |
| Cargo `~/.cargo/registry/cache` | `$CARGO_HOME/registry/cache` | Automatic allowed | Extracted sources and toolchains are preserved. |
| Gradle `~/.gradle/caches/*` | `$GRADLE_USER_HOME/caches/*` | Automatic allowed | Not present on the test machine. |
| Codex `~/.cache/codex-runtimes/codex-runtime-install-*` | `$XDG_CACHE_HOME/codex-runtimes/codex-runtime-install-*` | Automatic allowed | Verified on this machine (a temporary install with a `node-runtime.tar.xz`). `codex-primary-runtime` is protected. Retention applies. |
| Codex logs `~/.codex/log/*.log` | same | Manual only (logs) | 30-day retention by default. |
| Claude logs `Library/Logs/Claude` | `$XDG_CACHE_HOME/claude-cli-nodejs/*/mcp-logs-*/*.{jsonl,log,txt}` | Manual only (logs) | Only MCP log folders written by Claude Code; open logs are in use. Logs inside the retention period are summarized in one row per rule. Other Claude data (`~/.claude`, `~/.claude.json`) is protected. |
| Rust `target`, Swift `.build` | `<repo>/target` with `Cargo.toml`, `<repo>/.build` with `Package.swift`, inside configured project folders | Manual only (build) | Active `cargo`, `rustc`, `swift` keep them. |
| Git worktrees | Registered linked worktrees (see below) | Manual only | Never automatic. |
| Docker / OrbStack | `docker system df` | Inspection only | Read only when `docker.service` is already active. With socket activation the client would start the engine, so Sniff checks systemd first and never calls `docker` otherwise. No prune, no removal. Podman is not inspected. |
| SwiftPM `org.swift.swiftpm` | — | Not supported | No verified Linux location on the target system. |
| Homebrew | — | Not applicable | Omarchy uses pacman; Linuxbrew is not covered. |
| Sparkle/Electron updaters (`installer`) | — | Not applicable | The macOS updater folders do not exist on Linux; no Linux updater cache was verified. |
| Claude VM image | — | Not applicable | macOS Virtualization only. |
| Code signing clones | — | Not applicable | macOS only. |
| Codex app-server releases (`~/.codex/packages/…/releases/*`) | — | Not supported | Seen on this machine, but no rule can prove a release is unused or not a rollback target. |

## Always protected

Inside the home: `.codex/sessions`, `.codex/sqlite`, `.codex/auth.json`,
`.codex/config.toml`, `.claude`, `.claude.json`, `.ssh`, `.aws`, `.gnupg`,
`.config`, Sniff's own state, and `.cache/codex-runtimes/codex-primary-runtime`.
User exclusions protect the excluded path, everything inside it, and any
candidate that contains it.

## Classification

Each item is reported as ready, in use, preserved, needs review or no access,
with the reason. Partial measurements are shown as "at least" and never
authorize removal; an access error is never shown as zero bytes.

Sizes:

- **Logical**: sum of regular file sizes.
- **Allocated (estimate)**: `st_blocks × 512`, counted once per inode.
- **Expected to free**: the allocated bytes of inodes with no hardlink
  outside the item. The panel's selection total uses this figure.
- **Measured free-space change**: `statvfs` before and after cleanup.

On Btrfs (the default for Omarchy), reflinks, compression, subvolume
snapshots and hardlinks can make the freed space differ from the estimate.

Every entry's mount ID (`statx` `STATX_MNT_ID`) must match the candidate
root's, and every directory opened during removal is checked again. A
subvolume, another filesystem or a bind mount inside a candidate (even of the
same filesystem, which shares the device number) stops the walk and keeps the
item. A kernel that cannot report mount IDs keeps every item.

## Process checks

Sniff reads `/proc/<pid>/{fd,cwd,exe,root,maps,cmdline}` of the processes owned
by the current user. A candidate is kept when any of these hold:

1. a process of the user could not be inspected (the inventory is incomplete);
2. a process has a file, directory or mapping open inside it;
3. a command line names the path;
4. any inode of the candidate is open through another path (hardlinks);
5. a related tool is running (for example `npm install`, `cargo build`).

Processes of other users are not visible without privileges and are not
considered. `(sd-pam)`, systemd's non-dumpable PAM helper, is the only
unreadable process accepted. A process can start using a file after the
check; removal still compares every entry with the manifest right before
`unlinkat`.

## Removal

- Plans expire 15 minutes after the scan.
- Before removing, Sniff rechecks: plan age, rule, category enabled (and
  automatic eligibility), duplicates, protected paths and exclusions, the full
  manifest, npx MCP policy, retention, process usage, Git state for
  worktrees, and the manifest again after the usage check.
- Traversal opens every component from `/` with `O_NOFOLLOW|O_DIRECTORY`;
  symlinked ancestors and other filesystems are refused; internal symlinks
  are removed as links.
- Only manifest entries are removed, children first. A new or replaced entry
  stops the operation; hardlinks removed by the same operation do not
  invalidate it. A partial removal is recorded as such and the item must be
  scanned again.

## Worktrees

Discovery uses `git worktree list --porcelain -z` in repositories found under
the configured project folders and `~/.codex/worktrees` and
`~/.claude/worktrees`, deduplicated by device and inode. The first entry
(primary checkout) is never a candidate. Git runs with hooks, fsmonitor and
untracked cache disabled, `protocol.allow=never`, and every configured
`filter.*.clean`/`process` neutralized; it never fetches.

Administrative files that Codex and Git add to every worktree are accepted
only in their exact known form: `codex-thread.json` with just `version` and
`ownerThreadId`, `config.worktree` with just `[codex]
localEnvironmentConfigPath`, an empty `MERGE_RR`, and a `FETCH_HEAD` that is
empty or lists only fetched object IDs. They appear as recognized metadata in
the details. Any other content or file is local data.

A worktree is preserved when it is locked, has a Git operation in progress,
unknown or extra administrative metadata, submodules, hidden index flags,
staged/unstaged/untracked changes, unpublished commits (HEAD, ORIG_HEAD or its
reflog), commits not in the recorded default branch (`upstream/HEAD`,
`origin/HEAD`, or a single other remote's `HEAD`; `main`/`master` is never
assumed), shallow or grafted history, ignored files that are not regenerable
build output with a tracked marker (`node_modules`/`.next`/`.nuxt` with
`package.json`, `target` with `Cargo.toml`, `.build` with `Package.swift`,
`bin`/`obj` with a .NET project), sensitive names inside those folders
(`.env*`, databases, keys, `.claude`, `.codex`, `.git`…), nested repositories,
special files, visible use, changes within the retention period (14 days by
default, including administrative files), or when its repository is not under
a configured project folder. Manifests are limited to 180,000 entries and
administrative folders to 200.

Removal deletes the worktree folder with its `.git` file last, then its
validated administrative folder. No `git worktree remove --force`, prune or
branch deletion. If removal fails partway, the `.git` file is restored so Git
still recognizes what is left. There is no backup: only redundant copies that
Git can rebuild qualify.

## Scheduling

Off by default. `sniff schedule enable` writes a systemd user service and
timer (every 15 minutes; the run itself decides if it is due by the
configured interval). Automatic cleanup only touches enabled categories that
allow it; worktrees, npx, logs, builds and Docker are excluded by both the
planner and the executor. A running build or an incomplete process check
postpones the run by one hour.
