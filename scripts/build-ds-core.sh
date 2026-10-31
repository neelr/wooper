#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init Vendor/melonds
if git -C Vendor/melonds apply --check "$PWD/patches/melonds-resume-state.patch" 2>/dev/null; then
  git -C Vendor/melonds apply "$PWD/patches/melonds-resume-state.patch"
else
  git -C Vendor/melonds apply --reverse --check "$PWD/patches/melonds-resume-state.patch"
fi
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
make -C Vendor/melonds -j8 platform=ios-arm64 STATIC_LINKING=1 TARGET=libmelonds.a HAVE_WIFI=0 MINVERSION=-miphoneos-version-min=17.0 IOSSDK="$sdk"
cp Vendor/melonds/libmelonds.a DSCore/libmelonds.a
