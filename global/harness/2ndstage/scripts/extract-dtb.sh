#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Extract the DTB appended after the kernel in a stock/Lineage Android boot
# image.  MTK LK looks for this after decompressing a 64-bit kernel and uses it
# for dconfig/DTBO overlays before jumping to the kernel.
#
# Usage: extract-dtb.sh <boot.img> <out.dtb>

set -eu

[ $# -eq 2 ] || {
	echo "usage: $0 <boot.img> <out.dtb>" >&2
	exit 1
}

python3 - "$1" "$2" <<'PY'
import struct
import sys

img, out = sys.argv[1], sys.argv[2]
data = open(img, "rb").read()
if len(data) < 2048 or data[:8] != b"ANDROID!":
	raise SystemExit("not an Android boot image")

page = struct.unpack_from("<I", data, 36)[0] or 2048
ksize = struct.unpack_from("<I", data, 8)[0]
section = data[page:page + ksize]

magic = b"\xd0\x0d\xfe\xed"
pos = section.rfind(magic)
if pos < 0:
	raise SystemExit("no appended DTB found in the kernel section")

total = struct.unpack_from(">I", section, pos + 4)[0]
if total < 64 or pos + total > len(section):
	raise SystemExit("invalid appended DTB size")

open(out, "wb").write(section[pos:pos + total])
print(f"wrote {total} bytes to {out}")
PY
