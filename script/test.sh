#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/work/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/ModuleCache"
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
# Keep executable entry points built for testing separate from launchable products.
nice -n 10 swift test --build-system native --disable-sandbox --scratch-path work/tests-build --cache-path work/swift-cache --config-path work/swift-config --security-path work/swift-security -j 4 -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
