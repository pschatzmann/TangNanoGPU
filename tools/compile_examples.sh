#!/usr/bin/env bash
# Compiles every example with arduino-cli for the boards the library
# targets, plus the quad-SPI variants (TANGNANOGPU_LINK_QSPI) on the ESP32
# family. Examples whose optional library (TinyMaterialDesign, TinyH264,
# lvgl) is not installed are skipped. Prints PASS/FAIL/SKIP per build.
#
# Usage: tools/compile_examples.sh [fqbn ...]
#   default boards: esp32:esp32:esp32 esp32:esp32:esp32s3 rp2040:rp2040:rpipico
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/.."
CLI="${ARDUINO_CLI:-arduino-cli}"
BOARDS=("$@")
[[ ${#BOARDS[@]} -eq 0 ]] && BOARDS=(esp32:esp32:esp32 esp32:esp32:esp32s3 rp2040:rp2040:rpipico)

command -v "$CLI" >/dev/null || { echo "SKIP: arduino-cli not found (set ARDUINO_CLI)"; exit 0; }

needs() {  # example -> header of its optional library (empty if none)
  case "$1" in
    material-design) echo TinyMaterialDesign.h ;;
    video-player)    echo TinyH264Decoder.h ;;
    lvgl-example)    echo lvgl.h ;;
    *)               echo "" ;;
  esac
}
libdir="$("$CLI" config get directories.user 2>/dev/null)/libraries"

fail=0
for fqbn in "${BOARDS[@]}"; do
  for ex in "$LIB"/examples/*/; do
    name=$(basename "$ex")
    hdr=$(needs "$name")
    if [[ -n "$hdr" ]] && ! find "$libdir" -maxdepth 3 -name "$hdr" 2>/dev/null | grep -q .; then
      printf "SKIP %-24s %-24s (%s not installed)\n" "$fqbn" "$name" "$hdr"
      continue
    fi
    variants=("")
    [[ "$fqbn" == esp32:* ]] && variants+=("-DTANGNANOGPU_LINK_QSPI")
    for v in "${variants[@]}"; do
      out=$("$CLI" compile --fqbn "$fqbn" --build-property "compiler.cpp.extra_flags=$v" "$ex" 2>&1)
      if [[ $? -eq 0 ]]; then
        printf "PASS %-24s %-24s %s\n" "$fqbn" "$name" "${v:+quad}"
      else
        printf "FAIL %-24s %-24s %s\n" "$fqbn" "$name" "${v:+quad}"
        echo "$out" | grep -E "error" | head -5
        fail=1
      fi
    done
  done
done
exit $fail
