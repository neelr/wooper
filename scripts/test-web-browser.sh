#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/wooper-browser-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"
swiftc Wooper/Browser/WebAnnotationStore.swift Wooper/Browser/PencilPalmRejection.swift tests/WebAnnotationTests.swift -o "$test_dir/policy-tests"
"$test_dir/policy-tests"
# A small host avoids linking the device-only DS core into a simulator build.
mkdir -p "$test_dir/App"
cat > "$test_dir/App/TestHost.swift" <<'SWIFT'
import SwiftUI
@main struct TestHost: App {
    var body: some Scene { WindowGroup { Color.clear } }
}
SWIFT
python3 - "$repo_dir" "$test_dir" <<'PY'
import json, pathlib, sys
repo, target = map(pathlib.Path, sys.argv[1:])
q = lambda path: json.dumps(str(path))
(target / 'project.yml').write_text(f'''name: BrowserCheck
options:
  deploymentTarget:
    iOS: '17.0'
settings:
  base:
    SWIFT_VERSION: '5.9'
    CODE_SIGNING_ALLOWED: NO
targets:
  BrowserCheck:
    type: application
    platform: iOS
    sources:
      - App
      - {q(repo / 'Wooper/Browser')}
      - {q(repo / 'Wooper/Views/Theme.swift')}
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.neelr.BrowserUnitCheck
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        TARGETED_DEVICE_FAMILY: '1,2'
  BrowserCheckTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - {q(repo / 'tests/WebBrowserIntegrationTests.swift')}
    dependencies:
      - target: BrowserCheck
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.neelr.BrowserUnitCheckTests
        GENERATE_INFOPLIST_FILE: YES
schemes:
  BrowserCheck:
    build:
      targets:
        BrowserCheck: all
    test:
      targets: [BrowserCheckTests]
''')
PY
xcodegen generate --spec "$test_dir/project.yml"
xcodebuild -project "$test_dir/BrowserCheck.xcodeproj" -scheme BrowserCheck \
    -destination "${BROWSER_TEST_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5)}" \
    -derivedDataPath "$test_dir/build" -parallel-testing-enabled NO test
