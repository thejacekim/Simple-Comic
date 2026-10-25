#!/bin/bash
# Builds XADMaster.framework and UniversalDetector.framework (Universal: arm64 + x86_64)
# from the Vendor/ submodules and installs them into Frameworks/, where the app and
# QuickComic projects link and embed them from.
#
# Run once after cloning (and after updating the submodules):
#   git submodule update --init
#   scripts/build-frameworks.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/vendor"
DEPLOYMENT_TARGET=12.0

if [ ! -f "$ROOT/Vendor/XADMaster/XADMaster.xcodeproj/project.pbxproj" ] || \
   [ ! -f "$ROOT/Vendor/UniversalDetector/UniversalDetector.xcodeproj/project.pbxproj" ]; then
    echo "error: Vendor submodules missing. Run: git submodule update --init" >&2
    exit 1
fi

# The XADMaster scheme also builds UniversalDetector (its project expects it as a sibling directory).
# The deployment target is overridden here because the vendored projects ask for 10.9, which current
# Xcode rejects.
xcodebuild \
    -project "$ROOT/Vendor/XADMaster/XADMaster.xcodeproj" \
    -scheme XADMaster \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    CODE_SIGNING_ALLOWED=NO \
    build

PRODUCTS="$DERIVED/Build/Products/Release"
for fw in XADMaster UniversalDetector; do
    rm -rf "$ROOT/Frameworks/$fw.framework"
    cp -R "$PRODUCTS/$fw.framework" "$ROOT/Frameworks/"
    lipo -info "$ROOT/Frameworks/$fw.framework/$fw"
done
