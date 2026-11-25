#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Wrap a U-Boot payload in an Android boot image that the stock first stage can
# chainload.
#
# The kernel is:
#
#   0x0000 .. 0x0fff   ARM64 Linux Image header (code0 branches to 0x1000)
#   0x1000 ..          u-boot-dtb.bin, linked at GKIW_BOOTIMG_BASE +
#                      GKIW_BOOTIMG_KERNEL_OFFSET + 0x1000
#
# The first stage loads the image at base + kernel offset and executes the
# header, which branches to the U-Boot payload. `booti` sees a normal ARM64
# Image and does not relocate it because flags bit 3 is set.
#
# MTK LK expects the kernel at 0x40080000 (base 0x40078000 + offset 0x8000),
# a bootopt cmdline to select 64-bit mode, and an Image.gz kernel. Those are
# selected through the environment variables below.
#
# Usage: mkbootimg.sh <u-boot-dtb.bin> <output.img>

set -eu

PAYLOAD=$1
OUTPUT=$2
DTB=${3:-}

[ -f "$PAYLOAD" ] || {
	echo "mkbootimg: missing payload: $PAYLOAD" >&2
	exit 1
}

if ! command -v mkbootimg >/dev/null 2>&1; then
	echo "mkbootimg: mkbootimg not found (AOSP host tools)" >&2
	exit 1
fi

KERNEL=$(mktemp)
KERNEL_IMAGE=$KERNEL
RAMDISK=$(mktemp)
trap 'rm -f "$KERNEL" "$KERNEL".gz "$RAMDISK"' EXIT

: "${GKIW_BOOTIMG_HEADER_SIZE:=0x1000}"
: "${GKIW_BOOTIMG_PAGESIZE:=2048}"
: "${GKIW_BOOTIMG_BASE:=0x01000000}"
: "${GKIW_BOOTIMG_KERNEL_OFFSET:=0x0}"
: "${GKIW_BOOTIMG_COMPRESS:=none}"
: "${GKIW_BOOTIMG_DUMMY_RAMDISK:=0}"
: "${GKIW_BOOTIMG_DUMMY_RAMDISK_SIZE:=0}"
: "${GKIW_BOOTIMG_KERNEL_PAD_SIZE:=0}"
: "${GKIW_BOOTIMG_APPEND_DTB:=0}"
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

if [ "$GKIW_BOOTIMG_COMPRESS" = "gzip" ]; then
	if ! command -v gzip >/dev/null 2>&1; then
		echo "mkbootimg: gzip not found" >&2
		exit 1
	fi
	gzip -n -9 -c "$KERNEL" > "$KERNEL.gz"
	KERNEL_IMAGE=$KERNEL.gz
elif [ "$GKIW_BOOTIMG_COMPRESS" != "none" ]; then
	echo "mkbootimg: unknown compression: $GKIW_BOOTIMG_COMPRESS" >&2
	exit 1
fi

if [ "$GKIW_BOOTIMG_KERNEL_PAD_SIZE" != "0" ]; then
	CUR=$(wc -c < "$KERNEL_IMAGE")
	PAD=$((GKIW_BOOTIMG_KERNEL_PAD_SIZE))
	if [ "$CUR" -lt "$PAD" ]; then
		truncate -s "$PAD" "$KERNEL_IMAGE"
	fi
fi

if [ "$GKIW_BOOTIMG_APPEND_DTB" = "1" ]; then
	[ -n "$DTB" ] && [ -f "$DTB" ] || {
		echo "mkbootimg: missing appended DTB" >&2
		exit 1
	}
	# Stock MTK Image.gz carries the DTB after the gzip stream; LK expects
	# to find and pass it.  Append U-Boot's own DTB as the payload DTB.
	cat "$DTB" >> "$KERNEL_IMAGE"
fi

if [ -n "${GKIW_BOOTIMG_RAMDISK:-}" ]; then
	[ -f "$GKIW_BOOTIMG_RAMDISK" ] || {
		echo "mkbootimg: missing ramdisk: $GKIW_BOOTIMG_RAMDISK" >&2
		exit 1
	}
	cp "$GKIW_BOOTIMG_RAMDISK" "$RAMDISK"
elif [ "$GKIW_BOOTIMG_DUMMY_RAMDISK" = "1" ]; then
	# Some LK versions reject a boot image with a zero-size ramdisk, or
	# compute a zero ramdisk address from it.  A minimal gzip cpio archive
	# keeps the section valid without affecting the 2ndstage payload.
	python3 - "$RAMDISK" <<'PYGEN'
import gzip
import sys

fields = [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 11, 0]
header = b"070701" + b"".join(b"%08x" % f for f in fields)
body = header + b"TRAILER!!!\0"
body += b"\0" * ((4 - len(body) % 4) % 4)

with open(sys.argv[1], "wb") as out:
    out.write(gzip.compress(body, compresslevel=9, mtime=0))
PYGEN
	if [ "$GKIW_BOOTIMG_DUMMY_RAMDISK_SIZE" != "0" ]; then
		truncate -s "$((GKIW_BOOTIMG_DUMMY_RAMDISK_SIZE))" "$RAMDISK"
	fi
else
	: > "$RAMDISK"
fi

set -- --kernel "$KERNEL_IMAGE" --ramdisk "$RAMDISK" \
	--base "$GKIW_BOOTIMG_BASE" \
	--kernel_offset "$GKIW_BOOTIMG_KERNEL_OFFSET" \
	--pagesize "$GKIW_BOOTIMG_PAGESIZE" \
	--header_version 0 \
	--output "$OUTPUT"
[ -n "${GKIW_BOOTIMG_RAMDISK_OFFSET:-}" ] &&
	set -- "$@" --ramdisk_offset "$GKIW_BOOTIMG_RAMDISK_OFFSET"
[ -n "${GKIW_BOOTIMG_SECOND_OFFSET:-}" ] &&
	set -- "$@" --second_offset "$GKIW_BOOTIMG_SECOND_OFFSET"
[ -n "${GKIW_BOOTIMG_TAGS_OFFSET:-}" ] &&
	set -- "$@" --tags_offset "$GKIW_BOOTIMG_TAGS_OFFSET"
[ -n "${GKIW_BOOTIMG_CMDLINE:-}" ] &&
	set -- "$@" --cmdline "$GKIW_BOOTIMG_CMDLINE"

mkbootimg "$@"

# mkbootimg zeroes the address of an absent section even when the offset was
# supplied.  Some bootloaders validate those addresses anyway, so restore the
# stock values from the offsets.
python3 - "$OUTPUT" <<'PYPATCH'
import os
import struct
import sys

path = sys.argv[1]
base = int(os.environ.get("GKIW_BOOTIMG_BASE", "0"), 0)
data = bytearray(open(path, "rb").read())

def restore(addr_off, size_off, env):
    size = struct.unpack_from("<I", data, size_off)[0]
    addr = struct.unpack_from("<I", data, addr_off)[0]
    if size or addr:
        return
    if env in os.environ and os.environ[env]:
        struct.pack_into("<I", data, addr_off,
                         base + int(os.environ[env], 0))

restore(20, 16, "GKIW_BOOTIMG_RAMDISK_OFFSET")
restore(28, 24, "GKIW_BOOTIMG_SECOND_OFFSET")
open(path, "wb").write(data)
PYPATCH

echo "built: $OUTPUT"
