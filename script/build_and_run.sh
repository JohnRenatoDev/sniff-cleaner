#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="Sniff"
BUNDLE_ID="app.sniff.mac"
APP_BUNDLE="$ROOT_DIR/dist/Sniff.app"
DELIVERY="$ROOT_DIR/outputs/Sniff.app"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/work/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/work/ModuleCache"
mkdir -p work/ModuleCache work/swift-cache work/swift-config work/swift-security dist outputs

# Scope termination to our app only. No developer tool, browser or agent is stopped.
/usr/bin/python3 - <<'PY'
import fcntl,sys
from pathlib import Path
p=Path.home()/'Library/Application Support/Sniff/operation.lock'
if p.exists():
    with p.open('r+') as f:
        try: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit('O Sniff está analisando ou limpando. Aguarde ou cancele a análise antes de recompilar.')
PY
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build --build-system native --disable-sandbox --scratch-path work/app-build --cache-path work/swift-cache --config-path work/swift-config --security-path work/swift-security -j 4
BIN_DIR="$(swift build --build-system native --scratch-path work/app-build --show-bin-path)"
/usr/bin/python3 script/package_app.py --bin-dir "$BIN_DIR" --output-dir "$ROOT_DIR/outputs" --installer
cp work/packaging-icons/Sniff.png outputs/sniff-icon.png
cp Resources/Sniff.svg outputs/sniff-logo.svg

case "$MODE" in
    run) /usr/bin/open -n "$DELIVERY" ;;
    --verify|verify) /usr/bin/open -n "$DELIVERY"; sleep 1; pgrep -x Sniff >/dev/null; echo "Sniff compilado e aberto." ;;
    --validate-menu-bar) /usr/bin/open -n "$DELIVERY" --args --project-preview --validate-menu-bar "$ROOT_DIR/work/menu-bar-validation.json" ;;
    --debug|debug) lldb -- "$DELIVERY/Contents/MacOS/Sniff" ;;
    --logs|logs) /usr/bin/open -n "$DELIVERY"; /usr/bin/log stream --info --style compact --predicate 'process == "Sniff"' ;;
    --telemetry|telemetry) /usr/bin/open -n "$DELIVERY"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "app.sniff.mac"' ;;
    --build-only) echo "$DELIVERY" ;;
    *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;;
esac
