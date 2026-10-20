#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"
SIGNING_IDENTITY="${SNIFF_SIGNING_IDENTITY:--}"
ARCHITECTURES="${SNIFF_ARCHS:-arm64 x86_64}"
RELEASE_DIR="$ROOT_DIR/outputs/release/$VERSION"
TASK_BUILD="$(mktemp -d /private/tmp/sniff-release.XXXXXX)"
cleanup() {
    /usr/bin/python3 - "$TASK_BUILD" <<'PY'
import shutil,sys
from pathlib import Path
p=Path(sys.argv[1])
if p.parent==Path('/private/tmp') and p.name.startswith('sniff-release.'):
    shutil.rmtree(p)
PY
}
trap cleanup EXIT
for ITEM in Package.swift VERSION Sources Resources Tests script; do
    /usr/bin/ditto "$ROOT_DIR/$ITEM" "$TASK_BUILD/$ITEM"
done
mkdir -p "$TASK_BUILD/universal" "$RELEASE_DIR"
BIN_DIRS=()
ICON_BIN_DIR=""
for ARCH in $ARCHITECTURES; do
    case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
    (
        cd "$TASK_BUILD"
        nice -n 10 swift build --build-system native --disable-sandbox --configuration release --arch "$ARCH" --scratch-path ".build-$ARCH" -j 4 -Xswiftc -debug-prefix-map -Xswiftc "$TASK_BUILD=."
    )
    BIN_DIR="$(cd "$TASK_BUILD" && swift build --build-system native --configuration release --arch "$ARCH" --scratch-path ".build-$ARCH" --show-bin-path)"
    BIN_DIRS+=("$BIN_DIR")
    if [ "$ARCH" = "$(uname -m)" ]; then ICON_BIN_DIR="$BIN_DIR"; fi
done
for PRODUCT in Sniff SniffCLI SniffScheduler SniffInstaller; do
    INPUTS=()
    for BIN_DIR in "${BIN_DIRS[@]}"; do INPUTS+=("$BIN_DIR/$PRODUCT"); done
    if [ "${#INPUTS[@]}" -gt 1 ]; then
        /usr/bin/lipo -create "${INPUTS[@]}" -output "$TASK_BUILD/universal/$PRODUCT"
    else
        cp "${INPUTS[0]}" "$TASK_BUILD/universal/$PRODUCT"
    fi
done
cp "${ICON_BIN_DIR:-${BIN_DIRS[0]}}/SniffIcon" "$TASK_BUILD/universal/SniffIcon"
/usr/bin/ditto "${BIN_DIRS[0]}/Sniff_SniffCore.bundle" "$TASK_BUILD/universal/Sniff_SniffCore.bundle"
/usr/bin/python3 "$ROOT_DIR/script/package_app.py" --bin-dir "$TASK_BUILD/universal" --output-dir "$RELEASE_DIR" --identity "$SIGNING_IDENTITY" --installer
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$RELEASE_DIR/Sniff.app" "$RELEASE_DIR/Sniff-$VERSION-macos.zip"
mkdir -p "$TASK_BUILD/cli" "$TASK_BUILD/dmg"
cp "$RELEASE_DIR/Sniff.app/Contents/Helpers/sniff" "$TASK_BUILD/cli/sniff"
/usr/bin/ditto "$TASK_BUILD/universal/Sniff_SniffCore.bundle" "$TASK_BUILD/cli/Sniff_SniffCore.bundle"
cp "$ROOT_DIR/docs/cli.md" "$TASK_BUILD/cli/README.md"
tar -czf "$RELEASE_DIR/sniff-$VERSION-macos-cli.tar.gz" -C "$TASK_BUILD/cli" sniff Sniff_SniffCore.bundle README.md
/usr/bin/ditto "$RELEASE_DIR/Install Sniff.app" "$TASK_BUILD/dmg/Install Sniff.app"
cp "$ROOT_DIR/docs/INSTALL.txt" "$TASK_BUILD/dmg/README.txt"
/usr/bin/hdiutil create -volname "Sniff $VERSION" -srcfolder "$TASK_BUILD/dmg" -format UDZO -ov "$RELEASE_DIR/Sniff-$VERSION-macos.dmg"
if [ -n "${SNIFF_NOTARY_PROFILE:-}" ]; then
    if [ "$SIGNING_IDENTITY" = '-' ]; then echo "Developer ID signing is required for notarization." >&2; exit 2; fi
    xcrun notarytool submit "$RELEASE_DIR/Sniff-$VERSION-macos.dmg" --keychain-profile "$SNIFF_NOTARY_PROFILE" --wait
    xcrun stapler staple "$RELEASE_DIR/Sniff-$VERSION-macos.dmg"
    xcrun stapler validate "$RELEASE_DIR/Sniff-$VERSION-macos.dmg"
fi
/usr/bin/python3 "$ROOT_DIR/script/validate_release.py" "$RELEASE_DIR"
(
    cd "$RELEASE_DIR"
    shasum -a 256 "Sniff-$VERSION-macos.dmg" "Sniff-$VERSION-macos.zip" "sniff-$VERSION-macos-cli.tar.gz" > SHA256SUMS
)
echo "Release artifacts: $RELEASE_DIR"
