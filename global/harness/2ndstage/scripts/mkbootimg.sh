#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Wrap a U-Boot payload in an Android boot image that the stock first stage can
# chainload.
#
# The kernel is:
#
#   0x0000 .. 0x0fff   ARM64 Linux Image header (code0 branches to 0x1000)
#   0x1000 ..          u-boot-dtb.bin, linked at 0x01001000
#
# so the image loads at 0x01000000 and executes the header, which branches to
# the U-Boot payload. `booti` sees a normal ARM64 Image and does not relocate
# it because flags bit 3 is set.
#
# Usage: mkbootimg.sh <u-boot-dtb.bin> <output.img>

set -eu

PAYLOAD=$1
OUTPUT=$2
DTB=${3:-}
HEADER_VERSION=${4:-0}
DTB_OFFSET=${GKIW_BOOTIMG_DTB_OFFSET:-0x00100000}

[ -f "$PAYLOAD" ] || {
	echo "mkbootimg: missing payload: $PAYLOAD" >&2
	exit 1
}

[ -z "$DTB" ] || [ -f "$DTB" ] || {
	echo "mkbootimg: missing dtb: $DTB" >&2
	exit 1
}

if ! command -v mkbootimg >/dev/null 2>&1; then
	echo "mkbootimg: mkbootimg not found (AOSP host tools)" >&2
	exit 1
fi

KERNEL=$(mktemp)
EMPTY=$(mktemp)
trap 'rm -f "$KERNEL" "$EMPTY"' EXIT

: "${GKIW_BOOTIMG_HEADER_SIZE:=0x1000}"
: "${GKIW_BOOTIMG_PAGESIZE:=2048}"
: "${GKIW_BOOTIMG_BASE:=0x01000000}"
export GKIW_BOOTIMG_HEADER_SIZE

python3 - "$PAYLOAD" "$KERNEL" <<'PY'
import os
import struct
import sys

payload_path, kernel_path = sys.argv[1], sys.argv[2]
header_size = int(os.environ["GKIW_BOOTIMG_HEADER_SIZE"], 0)
payload_size = os.path.getsize(payload_path)
image_size = header_size + payload_size

# code0 branches to the payload at header_size.
code0 = 0x14000000 | (header_size // 4)

header = bytearray(header_size)
# code0, code1 (nop), text_offset, image_size, flags (bit 3: do not relocate),
# res2, res3, res4, magic ("ARM\x64"), res5.
struct.pack_into(
    "<IIQQQQQQII",
    header,
    0,
    code0,
    0xD503201F,
    0,
    image_size,
    0x8,
    0,
    0,
    0,
    0x644D5241,
    0,
)

with open(kernel_path, "wb") as out:
    out.write(header)
    with open(payload_path, "rb") as payload:
        while chunk := payload.read(1 << 20):
            out.write(chunk)
PY

: > "$EMPTY"

set -- \
	--kernel "$KERNEL" \
	--ramdisk "$EMPTY" \
	--base "$GKIW_BOOTIMG_BASE" \
	--kernel_offset 0x0 \
	--pagesize "$GKIW_BOOTIMG_PAGESIZE"

if [ -n "$DTB" ]; then
	set -- "$@" --dtb "$DTB" --dtb_offset "$DTB_OFFSET"
fi

mkbootimg "$@" \
	--header_version "$HEADER_VERSION" \
	--output "$OUTPUT"

echo "built: $OUTPUT"
