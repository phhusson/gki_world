#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the gki_world second-stage bootloader.
#
#   scripts/build.sh [--soc <2ndstage.conf>] [--src <dir>] [--build <dir>]
#
# The result is <build>/u-boot.bin. The source tree is managed: it is reset to
# the pinned U-Boot commit and the patches are applied on every run.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)

SOC_CONF=$ROOT/soc/amlogic/g12a/harness/2ndstage.conf
while [ $# -gt 0 ]; do
	case "$1" in
	--soc)
		SOC_CONF=$2
		shift 2
		;;
	--src)
		UBOOT_SRC=$2
		shift 2
		;;
	--build)
		BUILD=$2
		shift 2
		;;
	-h|--help)
		sed -n '2,9p' "$0"
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 1
		;;
	esac
done

. "$ROOT/global/harness/2ndstage/uboot.conf"
. "$SOC_CONF"

UBOOT_SRC=${UBOOT_SRC:-$ROOT/.bootloader/u-boot}
BUILD=${BUILD:-$ROOT/.bootloader/build-g12a}
JOBS=${JOBS:-$(nproc)}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

if [ ! -d "$UBOOT_SRC/.git" ]; then
	mkdir -p "$UBOOT_SRC"
	git -C "$UBOOT_SRC" init -q
	git -C "$UBOOT_SRC" remote add origin "$UBOOT_REPO"
fi

git -C "$UBOOT_SRC" fetch --depth=1 origin "$UBOOT_REF"
git -C "$UBOOT_SRC" checkout -q --detach FETCH_HEAD
git -C "$UBOOT_SRC" reset -q --hard FETCH_HEAD
git -C "$UBOOT_SRC" clean -qfd

for patch in "$ROOT"/global/harness/2ndstage/patches/*.patch; do
	echo "applying $(basename "$patch")"
	git -C "$UBOOT_SRC" apply "$patch"
done

mkdir -p "$BUILD"
make -C "$UBOOT_SRC" O="$BUILD" "$UBOOT_BASE_DEFCONFIG"
"$UBOOT_SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD" \
	"$BUILD/.config" "$ROOT/$UBOOT_FRAGMENT"
make -C "$UBOOT_SRC" O="$BUILD" olddefconfig
make -C "$UBOOT_SRC" O="$BUILD" -j"$JOBS" CROSS_COMPILE="$CROSS_COMPILE"

GKIW_BOOTIMG_BASE="$GKIW_BOOTIMG_BASE" \
GKIW_BOOTIMG_HEADER_SIZE="$GKIW_BOOTIMG_HEADER_SIZE" \
GKIW_BOOTIMG_PAGESIZE="$GKIW_BOOTIMG_PAGESIZE" \
"$ROOT/global/harness/2ndstage/scripts/mkbootimg.sh" \
	"$BUILD/u-boot-dtb.bin" "$BUILD/gkiw-2ndstage-boot.img"

echo "built: $BUILD/u-boot.bin"
