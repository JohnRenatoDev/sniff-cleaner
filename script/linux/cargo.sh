#!/usr/bin/env bash
# Resolves a working cargo: the one on PATH, else rustup's proxy in ~/.cargo/bin.
set -euo pipefail
if command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1; then
  exec cargo "$@"
elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  exec "$HOME/.cargo/bin/cargo" "$@"
fi
echo "cargo not found. Install Rust (rustup) first." >&2
exit 1
