#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the gki_world Linux image for the K-Touch i9.
#
# Usage:
#   device/ktouch/i9/build-linux.sh [--kernel <dir>] [--dtb <stock.dtb>]
#
# Environment:
#   GKIW_BOOTIMG_DTB  use this DTB as the boot image second stage (the stock
#                     device DTB is required until the mainline DTS is complete)
#   TMPDIR            scratch directory (defaults to .bootloader/tmp)
#
# The first bringup uses the raw arm64 Image at 0x48000000.  U-Boot cannot
# reliably copy a kernel to 0x45000000 on this board, and 0x48000000 avoids
# the second-stage page tables.  The boot image header addresses below are
# hints; the second-stage U-Boot relocates the ramdisk and DTB.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
KERNEL=$ROOT/.kernel/linux-6.18.y
OUT=$ROOT/.bootloader/build-ktouch-i9
JOBS=${JOBS:-$(nproc)}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
CC=${CC:-aarch64-linux-gnu-gcc}
DTB=${GKIW_BOOTIMG_DTB:-}
TMPDIR=${TMPDIR:-$ROOT/.bootloader/tmp}
export TMPDIR

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel) KERNEL=$2; shift 2 ;;
	--dtb) DTB=$2; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

KBUILD="make -C $KERNEL ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE"

$KBUILD defconfig
"$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$KERNEL" \
	"$KERNEL/.config" \
	"$ROOT/soc/mediatek/mt6739/config.fragment" \
	"$ROOT/device/ktouch/i9/config.fragment" >/dev/null
$KBUILD olddefconfig

# Blind-bringup instrumentation: memory earlycon, breadcrumbs and the
# entry-point markers.  It must be applied to a pristine kernel checkout.
for patch in "$ROOT"/global/harness/linux/patches/*.patch; do
	[ -e "$patch" ] || continue
	if git -C "$KERNEL" apply --check "$patch" 2>/dev/null; then
		echo "applying $(basename "$patch")"
		git -C "$KERNEL" apply "$patch"
	fi
done

cp "$ROOT/soc/mediatek/mt6739/mt6739.dtsi" \
   "$ROOT/device/ktouch/i9/mt6739-ktouch-i9.dts" \
   "$KERNEL/arch/arm64/boot/dts/mediatek/"
if ! grep -q mt6739-ktouch-i9 "$KERNEL/arch/arm64/boot/dts/mediatek/Makefile"; then
	echo 'dtb-$(CONFIG_ARCH_MEDIATEK) += mt6739-ktouch-i9.dtb' \
		>> "$KERNEL/arch/arm64/boot/dts/mediatek/Makefile"
fi

$KBUILD -j"$JOBS" Image dtbs

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root"
"$CC" -static -O2 -o "$TMP/root/init" "$ROOT/device/ktouch/i9/init/init.c"
(cd "$TMP/root" && find . | cpio -o -H newc 2>/dev/null | gzip -9) \
	> "$TMP/initramfs.cpio.gz"

if [ -z "$DTB" ]; then
	DTB=$KERNEL/arch/arm64/boot/dts/mediatek/mt6739-ktouch-i9.dtb
fi
[ -f "$DTB" ] || { echo "missing DTB: $DTB" >&2; exit 1; }

mkdir -p "$OUT"
mkbootimg \
	--kernel "$KERNEL/arch/arm64/boot/Image" \
	--ramdisk "$TMP/initramfs.cpio.gz" \
	--second "$DTB" \
	--base 0x48000000 \
	--kernel_offset 0x0 \
	--ramdisk_offset 0x02000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x04000000 \
	--pagesize 2048 \
	--header_version 0 \
	--cmdline "nokaslr maxcpus=1 cpuidle.off=1 earlycon=gkiw keep_bootcon ignore_loglevel loglevel=8" \
	--output "$OUT/boot-linux.img"

echo "built: $OUT/boot-linux.img"
