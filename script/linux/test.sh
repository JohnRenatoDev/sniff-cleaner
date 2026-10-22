#!/usr/bin/env bash
# Rust checks for the Linux core, CLI and plugin metadata. Fixtures only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARGO="$ROOT/script/linux/cargo.sh"
cd "$ROOT/rust"
echo "==> cargo fmt --check";  "$CARGO" fmt --all -- --check
echo "==> cargo clippy";       nice -n 19 "$CARGO" clippy --locked --all-targets -- -D warnings
echo "==> cargo test";         nice -n 19 "$CARGO" test --locked
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  echo "==> omarchy plugin validate"; omarchy-plugin-validate "$ROOT"
fi
echo "All Linux checks passed."
