#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Wrap the ARM32 Linux zImage, its DTB and the ACM initramfs in the v0 Android
# boot image that the Archos second stage boots.
#
# The load addresses are not optional: the second stage (and LK before it)
# honour the boot image header, and with the mkbootimg defaults the DTB lands
# at 0x01000100, inside the kernel image, so Linux dies before console init.
# Keep these in sync with device/archos/ac50fhe/harness/2ndstage.conf.
#
# Usage: mklinuximg.sh <zImage> <dtb> <initramfs.cpio.gz> <output.img>

set -eu

if [ $# -ne 4 ]; then
	echo "usage: $0 <zImage> <dtb> <initramfs.cpio.gz> <output.img>" >&2
	exit 1
fi

ZIMAGE=$1
DTB=$2
INITRAMFS=$3
OUTPUT=$4

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MKBOOTIMG=$HERE/../../../../global/harness/2ndstage/scripts/mkbootimg.sh

CMDLINE=${GKIW_CMDLINE:-maxcpus=1 cpuidle.off=1 ignore_loglevel panic=10 oops=panic}

GKIW_BOOTIMG_HEADER_SIZE=0 \
GKIW_BOOTIMG_COMPRESS=none \
GKIW_BOOTIMG_BASE=0x80000000 \
GKIW_BOOTIMG_PAGESIZE=2048 \
GKIW_BOOTIMG_KERNEL_OFFSET=0x00008000 \
GKIW_BOOTIMG_RAMDISK_OFFSET=0x02000000 \
GKIW_BOOTIMG_SECOND_OFFSET=0x00f00000 \
GKIW_BOOTIMG_TAGS_OFFSET=0x01e00000 \
GKIW_BOOTIMG_RAMDISK="$INITRAMFS" \
GKIW_BOOTIMG_SECOND="$DTB" \
GKIW_BOOTIMG_CMDLINE="$CMDLINE" \
	"$MKBOOTIMG" "$ZIMAGE" "$OUTPUT"
