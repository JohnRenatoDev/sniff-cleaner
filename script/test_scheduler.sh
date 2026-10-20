#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_DIR="$(mktemp -d /private/tmp/sniff-scheduler-test.XXXXXX)"
LABEL="app.sniff.fixture.$(uuidgen | tr '[:upper:]' '[:lower:]')"
DOMAIN="gui/$(id -u)"
cleanup() {
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    /usr/bin/python3 - "$TASK_DIR" <<'PY'
import shutil, sys
from pathlib import Path
p=Path(sys.argv[1])
if p.parent==Path('/private/tmp') and p.name.startswith('sniff-scheduler-test.'):
    shutil.rmtree(p)
PY
}
trap cleanup EXIT
BIN_DIR="$(swift build --build-system native --scratch-path work/app-build --show-bin-path)"
if [ ! -x "$BIN_DIR/SniffScheduler" ]; then
    swift build --build-system native --disable-sandbox --scratch-path work/app-build --product SniffScheduler -j 4
fi
/usr/bin/python3 - "$BIN_DIR/SniffScheduler" "$TASK_DIR" "$LABEL" <<'PY'
import plistlib,sys,shutil
from pathlib import Path
binary,root,label=sys.argv[1:]
p=Path(root)
runner=p/'SniffScheduler'
shutil.copy2(binary,runner)
runner.chmod(0o755)
job={'Label':label,'ProgramArguments':[str(runner),'--fixture-store',str(p/'state')], 'RunAtLoad':True, 'ProcessType':'Background', 'Nice':10, 'StandardOutPath':str(p/'stdout'), 'StandardErrorPath':str(p/'stderr')}
(p/'job.plist').write_bytes(plistlib.dumps(job))
PY
launchctl bootstrap "$DOMAIN" "$TASK_DIR/job.plist"
/usr/bin/python3 - "$TASK_DIR" <<'PY'
import json,sys,time
from pathlib import Path
p=Path(sys.argv[1])/'state'/'state.json'
for _ in range(80):
    if p.exists(): break
    time.sleep(.1)
if not p.exists():
    for name in ['stdout','stderr']:
        log=Path(sys.argv[1])/name
        if log.exists(): print(name, log.read_text())
    raise AssertionError('launchd did not wake fixture helper')
d=json.loads(p.read_text())
assert d['schedulerLastWake'] > 0
assert 'nenhuma limpeza' in d['schedulerMessage']
assert not d['history']
print('PASS: launchd woke the fixture helper; persisted wake; no cleaning; temporary job removed on exit.')
PY
launchctl print "$DOMAIN/$LABEL" | /usr/bin/awk '/runs =|last exit code =|state = exited/{print}'
