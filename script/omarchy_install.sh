#!/usr/bin/env bash
# Builds the sniff binary and installs the Omarchy plugin for the current user.
#
# What it does, and nothing else:
#   1. cargo build --release (rust/ workspace), at the lowest CPU priority
#   2. copies the binary to ~/.local/bin/sniff (refuses to replace a file it
#      did not install, unless --force-binary)
#   3. copies manifest.json, omarchy/, LICENSE and the plugin README to
#      ~/.config/omarchy/plugins/io.github.johnrenatodev.sniff/
#   4. runs `omarchy plugin validate` on that folder and asks the running
#      shell to rescan plugins
#   5. with --enable, enables the bar widget (right section)
# It never runs sudo, never enables scheduling and never cleans anything.
set -euo pipefail

ID="io.github.johnrenatodev.sniff"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"
ENABLE=0
FORCE_BIN=0
for arg in "$@"; do
  case "$arg" in
    --enable) ENABLE=1 ;;
    --force-binary) FORCE_BIN=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Building sniff (release)"
( cd "$ROOT/rust" && nice -n 19 "$ROOT/script/linux/cargo.sh" build --release --locked -p sniff-cli )
TARGET_DIR="$(cd "$ROOT/rust" && "$ROOT/script/linux/cargo.sh" metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
BUILT="$TARGET_DIR/release/sniff"
[[ -x $BUILT ]] || { echo "build output not found: $BUILT" >&2; exit 1; }

echo "==> Installing binary to $BIN_DIR/sniff"
mkdir -p "$BIN_DIR"
MARK="$HOME/.local/share/sniff/installed-binary"
if [[ -e $BIN_DIR/sniff && ! -f $MARK && $FORCE_BIN -eq 0 ]]; then
  echo "$BIN_DIR/sniff exists and was not installed by this script; use --force-binary to replace it." >&2
  exit 1
fi
install -m 0755 "$BUILT" "$BIN_DIR/sniff.new"
mv -f "$BIN_DIR/sniff.new" "$BIN_DIR/sniff"
mkdir -p "$(dirname "$MARK")"
printf '%s\n' "$BIN_DIR/sniff" > "$MARK"

echo "==> Installing plugin files to $PLUGIN_DIR"
STAGE="$(mktemp -d "${PLUGIN_DIR%/*}/.sniff-stage.XXXXXX" 2>/dev/null || { mkdir -p "${PLUGIN_DIR%/*}"; mktemp -d "${PLUGIN_DIR%/*}/.sniff-stage.XXXXXX"; })"
trap 'rm -rf "$STAGE"' EXIT
cp "$ROOT/manifest.json" "$ROOT/LICENSE" "$STAGE/"
mkdir -p "$STAGE/omarchy"
cp "$ROOT"/omarchy/*.qml "$ROOT"/omarchy/*.js "$ROOT/omarchy/README.md" "$STAGE/omarchy/"
omarchy-plugin-validate "$STAGE"
if [[ -d $PLUGIN_DIR ]]; then
  [[ -f $PLUGIN_DIR/manifest.json ]] && grep -q "\"$ID\"" "$PLUGIN_DIR/manifest.json" \
    || { echo "$PLUGIN_DIR exists and is not this plugin; not touching it." >&2; exit 1; }
  rm -rf "$PLUGIN_DIR"
fi
mv "$STAGE" "$PLUGIN_DIR"
trap - EXIT
omarchy-plugin-validate "$PLUGIN_DIR"
omarchy-shell -q shell rescanPlugins >/dev/null || true

if (( ENABLE )); then
  echo "==> Enabling the bar widget"
  for _ in $(seq 1 40); do
    omarchy-plugin-list --json 2>/dev/null | grep -q "\"$ID\"" && break
    sleep 0.05
  done
  omarchy-plugin-enable "$ID" --section right
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Note: $BIN_DIR is not on PATH; set the widget's 'sniff command' to $BIN_DIR/sniff." ;; esac
echo "Done. Scheduling stays off; nothing was scanned or removed."
