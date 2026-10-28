#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
task_dir="$(mktemp -d /tmp/wooper-comic-tests.XXXXXX)"
trap 'rm -rf "$task_dir"' EXIT
mkdir -p "$task_dir/Sources/ComicTests"
cp "$repo/Wooper/Comics/ComicImporter.swift" "$repo/tests/ComicImportTests.swift" "$task_dir/Sources/ComicTests/"
cat > "$task_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ComicTests", platforms: [.macOS(.v13)], dependencies: [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
], targets: [.executableTarget(name: "ComicTests", dependencies: ["ZIPFoundation"])])
SWIFT
swift run --package-path "$task_dir" ComicTests
