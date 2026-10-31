#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
work=$(mktemp -d /tmp/wooper-ds-test.XXXXXX)
trap 'if [[ ${DS_KEEP_TEST_WORK:-0} == 1 ]]; then echo "Test workspace: $work"; else rm -rf "$work"; fi' EXIT
git clone --quiet --local Vendor/melonds "$work/core"
git -C "$work/core" apply "$root/patches/melonds-resume-state.patch"
make -C "$work/core" -j8 platform=osx STATIC_LINKING=1 TARGET=libmelonds.a HAVE_WIFI=0 ARCHFLAGS='-arch arm64' > "$work/build.log" 2>&1 || { tail -40 "$work/build.log"; exit 1; }
common="$work/core/src/libretro/libretro-common"
mkdir -p "$work/objects" "$work/system" "$work/saves"
for file in compat/compat_strl.c compat/fopen_utf8.c compat/compat_posix_string.c compat/compat_strcasestr.c encodings/encoding_utf.c file/file_path.c streams/file_stream.c streams/file_stream_transforms.c string/stdstring.c vfs/vfs_implementation.c; do
  clang -O2 -I"$common/include" -c "$common/$file" -o "$work/objects/$(basename "$file").o"
done
python3 scripts/make-ds-test-rom.py "$work/test.nds"
clang++ -std=c++17 -O2 -IDSCore -I"$work/core/src" -I"$work/core/src/libretro" -I"$common/include" DSCore/DSCore.cpp tests/DSCoreSmoke.cpp "$work/core/libmelonds.a" "$work"/objects/*.o -o "$work/test"
"$work/test" "$work/test.nds" "$work/system" "$work/saves"

if [[ -n "${DS_TEST_ROM:-}" && -n "${DS_TEST_STATE:-}" ]]; then
  clang++ -std=c++17 -O2 -IDSCore -I"$common/include" DSCore/DSCore.cpp tests/DSResumeSmoke.cpp "$work/core/libmelonds.a" "$work"/objects/*.o -o "$work/resume"
  "$work/resume" "$DS_TEST_ROM" "$DS_TEST_STATE" "$work/system" "$work/saves"
fi
