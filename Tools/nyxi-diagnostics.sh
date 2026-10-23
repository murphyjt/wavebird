#!/bin/bash
# Local BLE diagnostics; a separate bundle, no managed virtual-HID entitlement.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Diagnostics \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- \
  CODE_SIGN_ENTITLEMENTS=Tools/NYXIDiagnostics.entitlements \
  PRODUCT_BUNDLE_IDENTIFIER=dev.local.wavebird.nyxidiagnostics \
  PRODUCT_NAME=WaveBirdNYXIDiagnostics \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG NYXI_DIAGNOSTICS' \
  build > build/diagnostics-build.log 2>&1 || {
    tail -60 build/diagnostics-build.log
    exit 1
  }
echo "Build: $PWD/build/Diagnostics/Build/Products/Debug/WaveBirdNYXIDiagnostics.app"
if [[ "${1:-}" != "--build-only" ]]; then
  echo "Log: $PWD/build/nyxi-diagnostics.log"
  open -n -a "$PWD/build/Diagnostics/Build/Products/Debug/WaveBirdNYXIDiagnostics.app" \
    --stdout "$PWD/build/nyxi-diagnostics.log" --stderr "$PWD/build/nyxi-diagnostics.log"
fi
