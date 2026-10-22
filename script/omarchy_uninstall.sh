#!/usr/bin/env bash
# Removes the Omarchy plugin and the binary installed by omarchy_install.sh.
# Disables the systemd user timer first if Sniff registered one. Settings and
# history in ~/.config/sniff and ~/.local/state/sniff are kept unless --purge.
set -euo pipefail

ID="io.github.johnrenatodev.sniff"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"
BIN="$HOME/.local/bin/sniff"
MARK="$HOME/.local/share/sniff/installed-binary"
PURGE=0
[[ ${1:-} == --purge ]] && PURGE=1

if [[ -x $BIN ]]; then
  "$BIN" schedule disable >/dev/null 2>&1 || true
fi
if omarchy-plugin-list --json 2>/dev/null | grep -q "\"$ID\""; then
  omarchy-plugin-disable "$ID" >/dev/null 2>&1 || true
fi
if [[ -d $PLUGIN_DIR ]]; then
  grep -q "\"$ID\"" "$PLUGIN_DIR/manifest.json" && rm -rf "$PLUGIN_DIR"
  omarchy-shell -q shell rescanPlugins >/dev/null || true
fi
if [[ -f $MARK && -e $BIN ]]; then
  rm -f "$BIN" "$MARK"
fi
if (( PURGE )); then
  rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/sniff" "${XDG_STATE_HOME:-$HOME/.local/state}/sniff"
fi
echo "Sniff plugin removed."
