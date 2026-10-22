# Sniff CLI on Linux

The `sniff` binary is built from `rust/` and shared by the terminal and the
Omarchy plugin. It supports English, Portuguese and Spanish (`--language`,
the saved `language` setting, or `LANGUAGE`/`LC_ALL`/`LC_MESSAGES`/`LANG`).

## Scan, review, clean

```sh
sniff scan                    # caches, project builds, worktrees, Docker (inspection)
sniff scan --quick            # caches only
sniff scan --worktrees --json # registered Git worktrees only
sniff categories              # categories and the Linux paths behind them
sniff list --ready
sniff plan --category npm
sniff plan --category npm --output ./cleanup-plan.json
sniff clean --plan ./cleanup-plan.json
```

Scanning never removes files. `list` reads the last saved scan. Without
filters, `plan` selects only enabled categories that allow automatic cleanup;
use repeated `--category` or repeated `--path` (not both) to select manual
categories. `plan` previews unless `--output <new-file>` (never overwritten,
mode 0600) or `--save` (a new file under `$XDG_STATE_HOME/sniff/plans/`) is
given. Plans expire 15 minutes after the scan.

`clean` prints the plan to stderr and asks you to type `CLEAN`. In scripts use
`--yes` with an explicit plan:

```sh
sniff clean --plan ./cleanup-plan.json --yes --json
```

### Worktrees

```sh
sniff scan --worktrees --json
sniff list --category worktree
sniff list --category worktree --ready
sniff list --category worktree --filter pending --search feature
sniff config --project ~/Work
sniff config --enable worktree
sniff plan --category worktree --output ./worktree-plan.json
sniff clean --plan ./worktree-plan.json
```

`--filter` accepts `all`, `ready`, `pending`, `in-use` and `preserved`;
`--search` matches path or branch. Worktrees are disabled by default, never in
unfiltered plans and never automatic. A repository must be inside a folder
added with `config --project` (or the worktree inside `~/.codex/worktrees` or
`~/.claude/worktrees`) before a worktree can be ready.

## Settings, history, scheduling

```sh
sniff config                                  # print settings (JSON)
sniff config --project ~/Work --exclude ~/Work/keep-this
sniff config --enable build --disable pnpm
sniff config --retention-days 21 --log-retention-days 45
sniff config --set-language pt
sniff status --json
sniff history --language es
sniff schedule status
sniff schedule enable --mode analyze --interval-hours 24
sniff schedule enable --mode automatic
sniff schedule disable
```

`config` options: `--enable`, `--disable`, `--project`, `--remove-project`,
`--exclude`, `--remove-exclusion`, `--retention-days`, `--log-retention-days`,
`--set-language`. Docker cannot be enabled. `schedule` reports both the saved
setting and what systemd says about the timer.

## Automation contract

- `--json` writes JSON to stdout; prompts and diagnostics go to stderr.
  `scan --json --progress` also writes `{"progress": "…"}` lines to stderr.
- Identifiers (`category`, `state`, `worktree.status`) are stable across
  languages; titles, reasons and details are localized.
- Dates are UTC RFC 3339.
- Sizes per item: `logicalBytes`, `allocatedBytes` (estimate) and
  `freeableBytes` (allocation not shared through hardlinks outside the item).
  Cleanup reports add `estimatedFreedBytes` and the measured
  `netFreeSpaceChange`.
- Errors with `--json`: `{"error": "…", "errorKey": "…", "exitCode": n}`.

| Exit code | Meaning |
| --- | --- |
| 0 | Success; cleanup removed every item |
| 1 | Runtime, file, lock or state error |
| 2 | Invalid command or options; plan errors (no scan, expired, empty, foreign home, invalid file) |
| 3 | Cleanup consent not given |
| 4 | Cleanup kept items or removed one partially |

## Files

| Path | Contents |
| --- | --- |
| `$XDG_CONFIG_HOME/sniff/settings.json` | Settings (0600) |
| `$XDG_STATE_HOME/sniff/state.json` | Last scan summary, history, scheduler state (0600) |
| `$XDG_STATE_HOME/sniff/scan-manifests.json` | File manifests of the last scan's candidates, read only by `plan` (0600) |
| `$XDG_STATE_HOME/sniff/sniff.lock` | Lock shared by the plugin, CLI and scheduler |
| `$XDG_STATE_HOME/sniff/plans/` | Plans saved by the plugin |

Directories are 0700. Writes are atomic. A corrupt or symlinked state file is
reported and never overwritten. Plans and state contain local paths and file
metadata; keep them private.

For tests, `SNIFF_HOME=<dir>` replaces the home and XDG directories, ignores
the tool path variables, and ignores command-line matches of tools (they run
against the real home, not the fixture). Open files and paths are still
checked.
