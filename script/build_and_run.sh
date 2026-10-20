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
swift build --build-system native --disable-sandbox --cache-path work/swift-cache --config-path work/swift-config --security-path work/swift-security -j 4
BIN_DIR="$ROOT_DIR/.build/debug"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Library/LaunchAgents"
cp "$BIN_DIR/Sniff" "$APP_BUNDLE/Contents/MacOS/Sniff"
cp "$BIN_DIR/SniffScheduler" "$APP_BUNDLE/Contents/Helpers/SniffScheduler"
ditto "$BIN_DIR/Sniff_SniffCore.bundle" "$APP_BUNDLE/Contents/Resources/Sniff_SniffCore.bundle"
"$BIN_DIR/SniffIcon" "$ROOT_DIR/work/SniffIcon.png"
mkdir -p work/Sniff.iconset
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" work/SniffIcon.png --out "work/Sniff.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" work/SniffIcon.png --out "work/Sniff.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
# ICNS is a container of the native-rendered PNG sizes. Avoid iconutil's dependence on GUI image services.
/usr/bin/python3 script/package_icon.py work/Sniff.iconset "$APP_BUNDLE/Contents/Resources/Sniff.icns"
cp work/SniffIcon.png outputs/sniff-icon.png
cp Resources/Sniff.svg outputs/sniff-logo.svg
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Sniff</string>
<key>CFBundleIdentifier</key><string>app.sniff.mac</string>
<key>CFBundleName</key><string>Sniff</string>
<key>CFBundleDisplayName</key><string>Sniff</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>pt</string><string>es</string></array>
<key>CFBundleIconFile</key><string>Sniff</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
cat > "$APP_BUNDLE/Contents/Library/LaunchAgents/app.sniff.scheduler.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.sniff.scheduler</string>
<key>BundleProgram</key><string>Contents/MacOS/Sniff</string>
<key>ProgramArguments</key><array><string>Sniff</string><string>--scheduled</string></array>
<key>StartInterval</key><integer>900</integer>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Background</string>
<key>LowPriorityIO</key><true/>
<key>Nice</key><integer>10</integer>
</dict></plist>
PLIST
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP_BUNDLE"
ditto "$APP_BUNDLE" "$DELIVERY"

case "$MODE" in
    run) /usr/bin/open -n "$DELIVERY" ;;
    --verify|verify) /usr/bin/open -n "$DELIVERY"; sleep 1; pgrep -x Sniff >/dev/null; echo "Sniff compilado e aberto." ;;
    --validate-menu-bar) /usr/bin/open -n "$DELIVERY" --args --validate-menu-bar "$ROOT_DIR/work/menu-bar-validation.json" ;;
    --debug|debug) lldb -- "$DELIVERY/Contents/MacOS/Sniff" ;;
    --logs|logs) /usr/bin/open -n "$DELIVERY"; /usr/bin/log stream --info --style compact --predicate 'process == "Sniff"' ;;
    --telemetry|telemetry) /usr/bin/open -n "$DELIVERY"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "app.sniff.mac"' ;;
    --build-only) echo "$DELIVERY" ;;
    *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;;
esac
