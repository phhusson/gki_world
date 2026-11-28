#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the gki_world USB ACM shell initramfs.
#
# Usage: BUSYBOX=/path/to/aarch64-static-busybox build-initramfs.sh [output]
#
# The busybox binary must be statically linked for aarch64. The result is a
# gzip-compressed cpio archive with /init and /bin/busybox.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=${1:-$ROOT/.bootloader/build-g12a/gkiw-acm-initramfs.cpio.gz}
BUSYBOX=${BUSYBOX:-}
CC=${CC:-aarch64-linux-gnu-gcc}

[ -n "$BUSYBOX" ] || {
	echo "build-initramfs: set BUSYBOX to a static aarch64 busybox" >&2
	exit 1
}
[ -f "$BUSYBOX" ] || {
	echo "build-initramfs: no such busybox: $BUSYBOX" >&2
	exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/bin"

"$CC" -static -O2 -o "$TMP/root/init" "$ROOT/global/harness/linux/init.c"
"$CC" -static -O2 -o "$TMP/root/bin/gkiw-i2c" "$ROOT/global/harness/linux/gkiw-i2c.c"
cp "$BUSYBOX" "$TMP/root/bin/busybox"
chmod +x "$TMP/root/init" "$TMP/root/bin/gkiw-i2c" "$TMP/root/bin/busybox"

mkdir -p "$(dirname "$OUT")"
(cd "$TMP/root" && find . | cpio -o -H newc 2>/dev/null | gzip -9) > "$OUT"
echo "built: $OUT"
