#!/bin/zsh
set -eu
cd "${0:A:h}/.."
build_dir="$PWD/.nj22-build"
mkdir -p "$build_dir/cache"
python3 - "$build_dir" <<'PY'
from pathlib import Path
import sys,plistlib
b=Path(sys.argv[1])
s=Path('WaveBird/Core/ControllerProfile.swift').read_text()
(b/'MatcherTypes.swift').write_text('@preconcurrency import CoreBluetooth\nimport Foundation\n'+s[s.index('struct BLEMatcher:'):])
s=Path('WaveBird/Core/NS2Commands.swift').read_text()
(b/'Commands.swift').write_text(s[:s.index('// Parsers for the response')])
s=Path('WaveBird/Core/NS2Console.swift').read_text()
(b/'ConsoleTypes.swift').write_text(s[:s.index('enum NS2ConsoleReport')])
(b/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.wavebird.nj22.transport','CFBundleName':'WaveBird NJ22 Transport Diagnostic','NSBluetoothAlwaysUsageDescription':'Test WaveBird Nintendo-mode initialization and read controller input. No firmware or pairing writes.'}))
PY
xcrun swiftc -swift-version 6 -module-cache-path "$build_dir/cache" -target arm64-apple-macosx26.0 Tools/NJ22TransportDiagnostic.swift WaveBird/Core/NS2BLE.swift WaveBird/Core/DeviceID.swift WaveBird/Core/TransportEvent.swift WaveBird/Transports/Transport.swift WaveBird/Transports/BLE/BLEAdvertisementDecoder.swift WaveBird/Transports/BLE/BLETransport.swift "$build_dir/MatcherTypes.swift" "$build_dir/Commands.swift" "$build_dir/ConsoleTypes.swift" -o "$build_dir/nj22-transport" -framework CoreBluetooth -framework Foundation -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$build_dir/Info.plist"
printf '%s\n' "Built $build_dir/nj22-transport (120-second diagnostic, no system-wide HID output)."
