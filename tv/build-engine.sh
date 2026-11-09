#!/bin/zsh
# Builds the Henge engine (engine/henge) for Apple TV: build/tv/libhengevm.a
# Same sources as Henge's `make ios-lib`, compiled against the appletvos SDK,
# with tv/compat/tvos_compat.h force-included for the calls tvOS's SDK forbids.
# Networking is the placeholder in tv/net_stub.c until libslirp is cross-built.
#
# Every file is attempted even after a failure, and all failures are listed at
# the end, so one CI run shows every tvOS incompatibility at once.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/engine/henge"
OUT="$ROOT/build/tv"
SDK="$(xcrun --sdk appletvos --show-sdk-path)"
MIN=17.0
CC=(xcrun --sdk appletvos clang -arch arm64 -mtvos-version-min=$MIN -isysroot "$SDK")
CFLAGS=(-std=c11 -Wall -Wextra -O2 -g -I"$H/core" -I"$H/host" -I"$H/devices")
COMPAT=(-include "$ROOT/tv/compat/tvos_compat.h")

objs=()
failed=()

build() { # source object flags...
    local src=$1 o=$2; shift 2
    mkdir -p "${o:h}"
    if "${CC[@]}" "$@" -c "$src" -o "$o" 2> "$o.log"; then
        objs+=("$o")
        grep -q "warning:" "$o.log" && echo "warn: ${src#$ROOT/}"
    else
        failed+=("${src#$ROOT/}")
        echo "::group::FAILED ${src#$ROOT/}"; cat "$o.log"; echo "::endgroup::"
    fi
}

for f in "$H"/core/*.c \
         "$H"/host/{prof_ios,jit_region,disk,vm,share,audio_mac,hvsparse,usb_host}.c \
         "$H"/devices/*.c; do
    rel="${f#$ROOT/}"
    extra=()
    [[ "${f:t}" == mmu.c ]] && extra=(-mgeneral-regs-only)   # as Henge's Makefile does
    build "$f" "$OUT/obj/${rel%.c}.o" "${CFLAGS[@]}" "${COMPAT[@]}" "${extra[@]}"
done

build "$H/devices/pvg_metal.m" "$OUT/obj/engine/henge/devices/pvg_metal.o" \
      "${CFLAGS[@]}" "${COMPAT[@]}" -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations
build "$H/host/enter.S" "$OUT/obj/engine/henge/host/enter.o"
build "$ROOT/tv/net_stub.c" "$OUT/obj/tv/net_stub.o" "${CFLAGS[@]}"
build "$ROOT/tv/compat/tvos_compat.c" "$OUT/obj/tv/compat/tvos_compat.o" -std=c11 -Wall -O2
build "$ROOT/tv/compat/tvos_compat_objc.m" "$OUT/obj/tv/compat/tvos_compat_objc.o" "${COMPAT[@]}" -fobjc-arc -Wall -O2

if (( ${#failed[@]} )); then
    echo "${#failed[@]} file(s) failed for tvOS:"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
rm -f "$OUT/libhengevm.a"
xcrun --sdk appletvos libtool -static -o "$OUT/libhengevm.a" "${objs[@]}"
echo "built $OUT/libhengevm.a (${#objs[@]} objects)"
