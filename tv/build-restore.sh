#!/bin/zsh
# Builds the macOS installer stack (idevicerestore and friends) for Apple TV:
# build/tv/libhengerestore.a. Rather than fork Henge's script, this runs a copy
# of it retargeted from iphoneos to appletvos (with tv/compat force-included),
# so upstream fixes keep flowing in.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/engine/henge"
SCRIPT="$H/tools/.build_tv_restore.sh"
sed -e 's/--sdk iphoneos/--sdk appletvos/g' \
    -e 's/SDKNAME=iphoneos/SDKNAME=appletvos/' \
    -e 's/-miphoneos-version-min=17.0/-mtvos-version-min=17.0/g' \
    -e 's|CC=(xcrun --sdk appletvos clang -arch arm64 -mtvos-version-min=17.0)|CC=(xcrun --sdk appletvos clang -arch arm64 -mtvos-version-min=17.0 -include '"$ROOT"'/tv/compat/tvos_compat.h)|' \
    -e 's/CMAKE_SYSTEM_NAME=iOS/CMAKE_SYSTEM_NAME=tvOS/' \
    -e 's|BUILD="$ROOT/build/ios"|BUILD="'"$ROOT"'/build/tv"|' \
    "$H/tools/build_ios_restore.sh" > "$SCRIPT"
grep -q appletvos "$SCRIPT" || { echo "retargeting failed: upstream script changed" >&2; exit 1; }
zsh "$SCRIPT"
rm -f "$SCRIPT"
ls -l "$ROOT/build/tv/libhengerestore.a"
