# Sniff Cleaner

Sniff is a native macOS app for reviewing development caches and temporary files before cleaning them up. Its dog mascot sniffs and wags its tail while a scan or cleanup is running.

The interface is available in English, Portuguese and Spanish. Choose a language in **Settings → General → Language**. App text changes immediately; some macOS menu actions require reopening the app.

## Build and run

Requires macOS 14 or later and a Swift 6.2 or newer toolchain.

```sh
./script/build_and_run.sh
```

This builds the Swift package, creates a locally signed application and opens it. Build products and local scan results are excluded from Git.

## Review before cleaning

1. Scan the Mac. Scanning does not remove files.
2. Check each item's path, status and reason for preservation.
3. Select the items you want to remove and choose **Review cleanup**.
4. Review the full paths and confirm permanent removal. Sniff rechecks the files and process usage before removing them.

Project roots, exclusions and retention periods are configurable in Settings. Excluding a path inside an item preserves the entire item. Initial selection is empty.

Automatic cleanup is optional and disabled by default. It only uses enabled categories of recreatable caches. Worktrees, Docker and code signing copies are inspection-only. Source code, sessions, credentials, databases, container volumes and the main runtime are preserved by default.

Allocated file sizes are estimates. Cleanup history reports the measured change in free space separately; APFS, snapshots, hardlinks and other applications can affect it.

## Tests

```sh
./script/test.sh
./script/test_scheduler.sh
```

Tests that remove files use dedicated temporary fixtures. The scheduler integration test creates and removes a temporary LaunchAgent without cleaning real user data.

## Distribution

This is a development preview with a local ad hoc signature. It has not been notarized by Apple. Developer ID signing and notarization are required before presenting it as a trusted, generally distributable macOS download.

See [architecture](docs/architecture.md) and [cleanup policy](docs/cleaning-policy.md) for implementation details and current limits.
