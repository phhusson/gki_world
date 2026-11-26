#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the gki_world second-stage bootloader.
#
#   scripts/build.sh [--soc <2ndstage.conf>] [--src <dir>] [--build <dir>]
#
# The result is <build>/<UBOOT_PAYLOAD> and the wrapped boot image.  The source
# tree is managed: it is reset to the pinned U-Boot commit and the patches are
# applied on every run.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)

TARGET_CONF=$ROOT/soc/amlogic/g12a/harness/2ndstage.conf
while [ $# -gt 0 ]; do
	case "$1" in
	--soc)
		TARGET_CONF=$2
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
		sed -n '2,10p' "$0"
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 1
		;;
	esac
done

# A relative --soc path is relative to the repository root, not to wherever
# the script was invoked from.
case "$TARGET_CONF" in
/*) ;;
*) TARGET_CONF=$ROOT/$TARGET_CONF ;;
esac
[ -f "$TARGET_CONF" ] || {
	echo "missing target config: $TARGET_CONF" >&2
	exit 1
}

. "$ROOT/global/harness/2ndstage/uboot.conf"
. "$TARGET_CONF"

UBOOT_SRC=${UBOOT_SRC:-$ROOT/.bootloader/u-boot}
BUILD=${BUILD:-$ROOT/.bootloader/build-${UBOOT_PLATFORM:-${GKIW_BUILD_NAME:-g12a}}}
JOBS=${JOBS:-$(nproc)}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
UBOOT_PAYLOAD=${UBOOT_PAYLOAD:-u-boot-dtb.bin}
GKIW_FLASH_IMAGE=${GKIW_FLASH_IMAGE:-gkiw-2ndstage-flash.img}

if [ ! -d "$UBOOT_SRC/.git" ]; then
	mkdir -p "$UBOOT_SRC"
	git -C "$UBOOT_SRC" init -q
	git -C "$UBOOT_SRC" remote add origin "$UBOOT_REPO"
fi

git -C "$UBOOT_SRC" fetch --depth=1 origin "$UBOOT_REF"
git -C "$UBOOT_SRC" checkout -q -f --detach FETCH_HEAD
git -C "$UBOOT_SRC" reset -q --hard FETCH_HEAD
git -C "$UBOOT_SRC" clean -qfd

# Generic patches live in global/, SoC support patches in the SoC layer and
# board patches in the device layer.  Sort the union by basename so the
# numbered series (0001..0013, 0100..) applies in order regardless of which
# directory a patch lives in.
PATCH_LIST=$(mktemp)
PATCH_SORTED=$(mktemp)
trap 'rm -f "$PATCH_LIST" "$PATCH_SORTED"' EXIT

for dir in "$ROOT/global/harness/2ndstage/patches" ${UBOOT_PATCH_DIRS:-}; do
	case "$dir" in
	/*) ;;
	*) dir="$ROOT/$dir" ;;
	esac
	if [ ! -d "$dir" ]; then
		echo "patch directory not found: $dir" >&2
		exit 1
	fi
	for patch in "$dir"/*.patch; do
		[ -e "$patch" ] || continue
		echo "$patch" >> "$PATCH_LIST"
	done
done

awk -F/ '{ print $NF "\t" $0 }' "$PATCH_LIST" |
	LC_ALL=C sort -k1,1 | cut -f2- > "$PATCH_SORTED"

while IFS= read -r patch; do
	echo "applying $(basename "$patch")"
	git -C "$UBOOT_SRC" apply "$patch"
done < "$PATCH_SORTED"

# Legacy compatibility for layers written before UBOOT_PATCH_DIRS.  These
# patches are applied after the sorted union rather than merged into it, so a
# series numbered 0001.. still follows the global 0001.. series.
if [ -n "${UBOOT_SOC_PATCH_DIR:-}" ]; then
	for patch in "$ROOT/$UBOOT_SOC_PATCH_DIR"/*.patch; do
		[ -e "$patch" ] || continue
		echo "applying $(basename "$patch")"
		git -C "$UBOOT_SRC" apply "$patch"
	done
fi

mkdir -p "$BUILD"
make -C "$UBOOT_SRC" O="$BUILD" "$UBOOT_BASE_DEFCONFIG"

# A target may name upstream fragments that must be merged before its own, for
# example board/qualcomm/qcom-phone.config.  Resolve them against the
# repository first and then the U-Boot tree.
set -- "$BUILD/.config"
if [ -n "${UBOOT_EXTRA_FRAGMENTS:-}" ]; then
	for fragment in $UBOOT_EXTRA_FRAGMENTS; do
		case "$fragment" in
		/*) ;;
		*)
			if [ -f "$ROOT/$fragment" ]; then
				fragment=$ROOT/$fragment
			else
				fragment=$UBOOT_SRC/$fragment
			fi
			;;
		esac
		set -- "$@" "$fragment"
	done
fi
set -- "$@" "$ROOT/$UBOOT_FRAGMENT"
"$UBOOT_SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD" "$@"
make -C "$UBOOT_SRC" O="$BUILD" olddefconfig
make -C "$UBOOT_SRC" O="$BUILD" -j"$JOBS" CROSS_COMPILE="$CROSS_COMPILE"

GKIW_BOOTIMG_BASE="$GKIW_BOOTIMG_BASE" \
GKIW_BOOTIMG_HEADER_SIZE="$GKIW_BOOTIMG_HEADER_SIZE" \
GKIW_BOOTIMG_PAGESIZE="$GKIW_BOOTIMG_PAGESIZE" \
GKIW_BOOTIMG_HEADER_VERSION="${GKIW_BOOTIMG_HEADER_VERSION:-0}" \
GKIW_BOOTIMG_KERNEL_OFFSET="${GKIW_BOOTIMG_KERNEL_OFFSET:-0x0}" \
GKIW_BOOTIMG_RAMDISK_OFFSET="${GKIW_BOOTIMG_RAMDISK_OFFSET:-}" \
GKIW_BOOTIMG_SECOND_OFFSET="${GKIW_BOOTIMG_SECOND_OFFSET:-}" \
GKIW_BOOTIMG_TAGS_OFFSET="${GKIW_BOOTIMG_TAGS_OFFSET:-}" \
GKIW_BOOTIMG_CMDLINE="${GKIW_BOOTIMG_CMDLINE:-}" \
GKIW_BOOTIMG_OS_VERSION="${GKIW_BOOTIMG_OS_VERSION:-}" \
GKIW_BOOTIMG_OS_PATCH_LEVEL="${GKIW_BOOTIMG_OS_PATCH_LEVEL:-}" \
GKIW_BOOTIMG_COMPRESS="${GKIW_BOOTIMG_COMPRESS:-none}" \
GKIW_BOOTIMG_DUMMY_RAMDISK="${GKIW_BOOTIMG_DUMMY_RAMDISK:-0}" \
GKIW_BOOTIMG_DUMMY_RAMDISK_SIZE="${GKIW_BOOTIMG_DUMMY_RAMDISK_SIZE:-0}" \
GKIW_BOOTIMG_KERNEL_PAD_SIZE="${GKIW_BOOTIMG_KERNEL_PAD_SIZE:-0}" \
GKIW_BOOTIMG_IMAGE_PAD_SIZE="${GKIW_BOOTIMG_IMAGE_PAD_SIZE:-0}" \
GKIW_BOOTIMG_RAMDISK="${GKIW_BOOTIMG_RAMDISK:-}" \
GKIW_BOOTIMG_APPEND_DTB="${GKIW_BOOTIMG_APPEND_DTB:-0}" \
GKIW_BOOTIMG_TRAILER="${GKIW_BOOTIMG_TRAILER:-}" \
"$ROOT/global/harness/2ndstage/scripts/mkbootimg.sh" \
	"$BUILD/$UBOOT_PAYLOAD" "$BUILD/$GKIW_FLASH_IMAGE" \
	"${GKIW_BOOTIMG_DTB:-$BUILD/u-boot.dtb}"

rm -f "$BUILD/gkiw-2ndstage-boot.img" "$BUILD/gkiw-2ndstage-selfboot.img" "$BUILD/gkiw-2ndstage-fastboot.img"
echo "built: $BUILD/$UBOOT_PAYLOAD"
