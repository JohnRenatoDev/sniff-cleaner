# Sniff CLI

The `sniff` command uses the same scanner, preferences, cleanup checks and history as the macOS app. Requires macOS 14 or later. English, Portuguese and Spanish are supported.

## Install

The animated installer can install a symlink at `~/.local/bin/sniff`. It points to the command inside the installed app, so an app update also updates the CLI. The installer leaves shell profiles alone. If needed, add this line to your shell configuration:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Alternatively, extract the CLI archive and keep `sniff` beside `Sniff_SniffCore.bundle`. You can run it in place or link to it from a folder on PATH. The resource bundle is required for translated output. The preview is locally signed and not notarized.

## Scan, review, clean

```sh
sniff --help --language en
sniff scan --quick
sniff categories
sniff list --ready
sniff plan --category npm
sniff plan --category npm --output ./cleanup-plan.json
sniff clean --plan ./cleanup-plan.json
```

Scanning never removes files. Without `--quick`, scans also inspect registered project folders, worktrees, Docker and other manual categories. `list` reads the last saved scan. Without filters, `plan` selects only enabled categories of recreatable caches. Use repeated `--category` options or repeated `--path` options for exact paths; the two filters cannot be mixed.

`plan` previews candidates unless `--output` is given. The exported JSON file is private (mode 0600), includes the file manifest and expires **15 minutes after the scan**. Existing files are never overwritten. Keep the plan private: it contains local paths and file metadata.

`clean` previews the plan and asks you to type **CLEAN**. For an explicitly approved automation, use:

```sh
sniff clean --plan ./cleanup-plan.json --yes --json
```

`--yes` approves only the supplied plan. Before removal, Sniff rechecks its age, home directory, category settings, exclusions, file identities, timestamps and active processes. Changed, excluded, disabled or busy items are kept. MCP environments in npx are preserved even if a plan is edited. A partial failure is recorded and requires a new scan; deletion cannot be rolled back.

## Settings and history

```sh
sniff config
sniff config --project /absolute/path/to/projects
sniff config --enable build
sniff config --exclude /absolute/path/to/keep
sniff config --disable npm
sniff status --json
sniff history --language pt
```

Manual cleanup categories require explicit enablement and selection. Worktrees, Docker and code signing copies remain inspection-only. The CLI reports saved scheduler settings; use the app to register or disable its macOS background service. It does not install cron jobs.

The default state directory is `~/Library/Application Support/Sniff`. `--state-dir <directory>` selects a separate state store for every command; it does not change the home directory bound to cleanup plans. GUI, CLI and scheduler share an operation lock. Corrupt state is reported instead of silently overwritten.

## Automation contract

`--json` writes JSON to stdout; diagnostics and cleanup confirmation go to stderr. Category and state identifiers are stable and untranslated. `--language en|pt|es|system` applies to the current invocation without changing the app language. JSON dates use ISO 8601.

| Exit code | Meaning |
| --- | --- |
| 0 | Command completed; cleanup removed every selected item |
| 1 | Runtime, file or state error |
| 2 | Invalid command or options |
| 3 | Cleanup consent was not given |
| 4 | Cleanup completed with kept items or a partial removal |

Reported allocated bytes are estimates. The measured change in volume free space is separate and may be affected by APFS, snapshots, hardlinks and other processes.
