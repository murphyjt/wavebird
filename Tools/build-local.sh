#!/bin/bash
# Full local app, ordinary ad-hoc signature, no provisioning profile.
# Virtual HID creation still needs a runtime check on the user's macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/Local \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- \
  CODE_SIGN_ENTITLEMENTS= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=NO \
  PRODUCT_BUNDLE_IDENTIFIER=dev.local.wavebird.hyperion3 PRODUCT_NAME=WaveBirdLocal \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  build > build/local-build.log 2>&1 || {
    tail -60 build/local-build.log
    exit 1
  }
echo "Build: $PWD/build/Local/Build/Products/Debug/WaveBirdLocal.app"
if [[ "${1:-}" != "--build-only" ]]; then
  echo "Log: $PWD/build/local-run.log"
  open -a "$PWD/build/Local/Build/Products/Debug/WaveBirdLocal.app" \
    --stdout "$PWD/build/local-run.log" --stderr "$PWD/build/local-run.log"
fi
