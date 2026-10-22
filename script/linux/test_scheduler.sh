#!/usr/bin/env bash
# Registers a temporary systemd user timer in fixture mode, waits for it to
# wake the service, checks the recorded run, then disables and removes it.
# Uses a throwaway SNIFF_HOME; the real settings, history and caches are not
# read or changed, and nothing is scanned or removed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
( cd "$ROOT/rust" && nice -n 19 "$ROOT/script/linux/cargo.sh" build -q -p sniff-cli )
TARGET_DIR="$(cd "$ROOT/rust" && "$ROOT/script/linux/cargo.sh" metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
SNIFF="$TARGET_DIR/debug/sniff"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/sniff-scheduler-fixture.XXXXXX")"
export SNIFF_HOME="$FIX/home"
mkdir -p "$SNIFF_HOME"
UNIT="sniff-fixture-$$"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
cleanup() {
  "$SNIFF" schedule disable --fixture --unit-name "$UNIT" --json >/dev/null 2>&1 || true
  rm -rf "$FIX"
}
trap cleanup EXIT

echo "==> register $UNIT.timer (fixture)"
"$SNIFF" schedule enable --fixture --unit-name "$UNIT" --json | tee "$FIX/enable.json"
python3 - "$FIX/enable.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = d["registration"]
assert r["unit_files_present"] and r["enabled"] and r["active"], r
print("registered: enabled and active")
PY
grep -q 'scheduled-run "--fixture"' "$UNIT_DIR/$UNIT.service"
grep -q "IOSchedulingClass=idle" "$UNIT_DIR/$UNIT.service"

echo "==> wait for the timer to wake the service"
STATE="$SNIFF_HOME/.local/state/sniff/state.json"
for _ in $(seq 1 60); do
  [[ -f $STATE ]] && grep -q schedule.fixture_run "$STATE" && break
  sleep 0.5
done
python3 - "$STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["scheduler_last_wake"] > 0, s
assert s["scheduler_message"]["k"] == "schedule.fixture_run", s
assert s["history"] == [] and s["last_scan"] is None, "fixture run must not scan or clean"
print("woke at", s["scheduler_last_wake"], "-", s["scheduler_message"]["k"])
PY
systemctl --user show "$UNIT.service" -p Result -p ExecMainStatus

echo "==> disable and remove"
"$SNIFF" schedule disable --fixture --unit-name "$UNIT" --json >/dev/null
[[ ! -e $UNIT_DIR/$UNIT.timer && ! -e $UNIT_DIR/$UNIT.service ]]
if systemctl --user is-enabled "$UNIT.timer" >/dev/null 2>&1; then echo "timer still enabled" >&2; exit 1; fi
echo "OK: registration, wake-up, fixture execution and removal verified"
