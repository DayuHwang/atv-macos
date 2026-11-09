#!/bin/zsh
# Builds the Henge engine (engine/henge) for Apple TV: build/tv/libhengevm.a
# Same sources as Henge's `make ios-lib`, compiled against the appletvos SDK.
# Networking is the placeholder in tv/net_stub.c until libslirp is cross-built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/engine/henge"
OUT="$ROOT/build/tv"
SDK="$(xcrun --sdk appletvos --show-sdk-path)"
MIN=17.0
CC=(xcrun --sdk appletvos clang -arch arm64 -mtvos-version-min=$MIN -isysroot "$SDK")
CFLAGS=(-std=c11 -Wall -Wextra -O2 -g -I"$H/core" -I"$H/host" -I"$H/devices")

srcs=("$H"/core/*.c
      "$H"/host/{prof_ios,jit_region,disk,vm,share,audio_mac,hvsparse,usb_host}.c
      "$H"/devices/*.c
      "$ROOT/tv/net_stub.c")

objs=()
for f in "${srcs[@]}"; do
    rel="${f#$ROOT/}"
    o="$OUT/obj/${rel%.c}.o"
    mkdir -p "${o:h}"
    extra=()
    [[ "${f:t}" == mmu.c ]] && extra=(-mgeneral-regs-only)   # as Henge's Makefile does
    "${CC[@]}" "${CFLAGS[@]}" "${extra[@]}" -c "$f" -o "$o"
    objs+=("$o")
done

o="$OUT/obj/engine/henge/devices/pvg_metal.o"; mkdir -p "${o:h}"
"${CC[@]}" "${CFLAGS[@]}" -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations \
    -c "$H/devices/pvg_metal.m" -o "$o"; objs+=("$o")
o="$OUT/obj/engine/henge/host/enter.o"
"${CC[@]}" -c "$H/host/enter.S" -o "$o"; objs+=("$o")

rm -f "$OUT/libhengevm.a"
xcrun --sdk appletvos libtool -static -o "$OUT/libhengevm.a" "${objs[@]}"
echo "built $OUT/libhengevm.a (${#objs[@]} objects)"
