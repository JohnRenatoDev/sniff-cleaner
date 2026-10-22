# Sniff on Linux: architecture

The Linux port lives next to the macOS app in the same repository. The
SwiftUI app, its packages and scripts are unchanged; Linux adds a Rust
workspace, an Omarchy plugin and Linux scripts.

```
rust/                      Cargo workspace
  crates/sniff-core/       library: rules, scanning, worktrees, plans, removal, state
  crates/sniff-cli/        `sniff` binary (CLI and the plugin's backend)
omarchy/                   QML frontend loaded by omarchy-shell
  BarWidget.qml            bar button; loads Panel.qml
  Panel.qml                state, CLI calls, keyboard
  ListPane / ReviewPane / ResultPane / HistoryPane / SettingsPane.qml
  CliCall.qml              one `sniff` invocation (argv, JSON, exit code)
  SniffDog.qml, DogMotion.js  the dachshund and its motion (port of SniffIdentity)
  Format.js, Label.qml     sizes, local dates, text style
manifest.json              Omarchy plugin manifest (repository root, as Omarchy requires)
script/omarchy_install.sh  build + install for the current user
script/omarchy_uninstall.sh
script/linux/              cargo wrapper, test runner, scheduler test
docs/linux/                this documentation
```

## Division of work

| Layer | Responsibility |
| --- | --- |
| `sniff-core` | Every decision: which paths are recognized, classification, retention, process checks, Git checks, plans, revalidation and removal. No UI, no network, no model calls. |
| `sniff-cli` | Argument parsing, localized text and JSON output, exit codes, confirmation, the operation lock and persistence calls. |
| `omarchy/*.qml` | Presentation only. Runs fixed `sniff` subcommands with argument arrays (Quickshell `Process`, never a shell) and renders their JSON. It cannot remove anything except by running `sniff clean --plan <file> --yes` after the user confirms the reviewed plan. |

The plugin follows the Omarchy 4 contract verified on this machine
(`/usr/share/omarchy/shell/README.md`, `omarchy-plugin-validate`) and the
public plugin guide: a `bar-widget` with `entryPoints.barWidget`, a namespaced
id (`io.github.johnrenatodev.sniff`), no symlinks, and the shared UI kit
(`qs.Ui`: `BarWidget`, `Panel`, `KeyboardPanel`, `PanelKeyCatcher`, `Button`,
`TextField`). It does not start a second Quickshell process.

## Core modules (`sniff-core/src`)

| Module | Contents |
| --- | --- |
| `model.rs` | Categories, finding states, worktree assessment, reports, preferences, persisted state. Messages are stored as keys plus arguments. |
| `catalog.rs` | Linux rule catalog (paths from documented environment variables and XDG defaults), protected paths, rule validation. |
| `paths.rs` | Canonicalization, containment, symlink-ancestor checks. |
| `fsx.rs` | Descriptor-relative traversal and removal (`openat` with `O_NOFOLLOW`, `fstatat(AT_SYMLINK_NOFOLLOW)`, `unlinkat`), manifests, free-space measurement. |
| `procs.rs` | `/proc` inventory: open files, working directories, executables, mappings and command lines of the user's processes. |
| `scanner.rs` | Discovery and classification of rule targets, project builds and Docker inspection. |
| `worktree.rs` | Git worktree discovery, inspection, revalidation and removal. |
| `plan.rs` | Selection, plan files, expiry. |
| `executor.rs` | Per-item revalidation and removal, report application. |
| `store.rs` | XDG persistence, atomic private writes, shared `flock`. |
| `schedule.rs` | systemd user timer registration and the scheduled run. |
| `command.rs` | Fixed external programs (git, systemctl, docker): argv only, reduced environment, timeout, output cap. |
| `i18n.rs` | English, Portuguese and Spanish catalog, language resolution, byte formatting. |

## Dependencies

| Crate | Why |
| --- | --- |
| `rustix` | Safe wrappers for `openat`, `fstatat`, `unlinkat`, `fstatvfs`, `flock`, `kill`, `getuid` without hand-written `unsafe`. |
| `serde`, `serde_json` | State, plan files and the CLI/plugin JSON contract. |

No async runtime, argument-parsing or time crates: the CLI parser is small,
dates are UTC RFC 3339 computed in `store.rs`, and long work is bounded by
entry limits instead of concurrency.

## Data flow

1. `sniff scan` captures a process inventory, applies the catalog, discovers
   projects and worktrees, and saves the scan (with manifests of ready items)
   to `$XDG_STATE_HOME/sniff/state.json`, with file manifests in
   `scan-manifests.json` so listing stays fast.
2. `sniff list` and the panel read that scan.
3. `sniff plan --path … --save` (panel) or `--output <file>` (CLI) writes a
   private plan containing the selected findings and their manifests.
4. `sniff clean --plan <file>` re-reads the plan, takes the lock, revalidates
   each item and removes it, records the outcome and free-space change.

## Low impact

Scans are single-threaded walks with fixed entry limits (180,000 per item,
15,000 per log folder, 7,000 folders for project discovery). The scheduler
service runs with `Nice=19`, `IOSchedulingClass=idle` and
`CPUSchedulingPolicy=idle`, exits after each run, and postpones when a build
is running. The dog animation only runs while a command is in progress.
