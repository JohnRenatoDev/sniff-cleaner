#!/usr/bin/env bash
# Points the Omarchy widget at a fixture home so the whole panel flow (scan,
# select, review, confirm, result, history) can be exercised without real
# data. `setup` creates sample caches in a new temporary directory and a
# wrapper that runs `sniff` with SNIFF_HOME set; `restore` points the widget
# back at `sniff`. The fixture directory is left for you to delete.
set -euo pipefail
ID="io.github.johnrenatodev.sniff"
SNIFF_BIN="${SNIFF_BIN:-$HOME/.local/bin/sniff}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/sniff-panel-fixture"

case "${1:-}" in
  setup)
    FIX="$(mktemp -d "${TMPDIR:-/tmp}/sniff-panel-fixture.XXXXXX")"
    H="$FIX/home"
    mkdir -p "$H/.npm/_cacache/content-v2" "$H/.cache/pip/http-v2" "$H/.cache/codex-runtimes/codex-runtime-install-demo/payload" "$H/.codex/log"
    head -c 2000000 /dev/zero > "$H/.npm/_cacache/content-v2/blob"
    head -c 500000 /dev/zero > "$H/.cache/pip/http-v2/wheel"
    head -c 800000 /dev/zero > "$H/.cache/codex-runtimes/codex-runtime-install-demo/payload/node.tar"
    echo "old" > "$H/.codex/log/old.log"
    find "$H/.cache/codex-runtimes" "$H/.codex/log" -exec touch -h -d "60 days ago" {} +
    mkdir -p "$FIX/bin"
    printf '#!/bin/sh\nSNIFF_HOME=%q exec %q "$@"\n' "$H" "$SNIFF_BIN" > "$FIX/bin/sniff-fixture"
    chmod +x "$FIX/bin/sniff-fixture"
    printf '%s\n' "$FIX" > "$STATE_FILE"
    omarchy-bar set "$ID" sniffBinary "$FIX/bin/sniff-fixture" >/dev/null
    echo "Widget now uses the fixture home $H"
    ;;
  restore)
    omarchy-bar set "$ID" sniffBinary sniff >/dev/null
    [[ -f $STATE_FILE ]] && echo "Fixture left at $(cat "$STATE_FILE"); delete it when done." && rm -f "$STATE_FILE"
    echo "Widget restored to the real sniff command."
    ;;
  *) echo "usage: $0 setup|restore" >&2; exit 2 ;;
esac
