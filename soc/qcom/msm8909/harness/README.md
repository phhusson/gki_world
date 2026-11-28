# MSM8909 second-stage bootloader

Development-only second stage for Qualcomm Snapdragon 210 phones. The first
board is the Archos 50f Helium (`AC50FHE`, msm8909); the device layer is
`device/archos/ac50fhe`.

The mechanism is the shared one in `global/harness/2ndstage/`. This directory
adds the MSM8909 board data and the small U-Boot driver pieces that upstream
does not have.

## Boot chain

The stock bootloader is Qualcomm LK (`aboot`) and exposes the usual Android
fastboot interface. It loads an Android boot image from `boot` (or accepts one
with `fastboot boot`) and jumps to its kernel payload.

The K-Touch i9 port already showed the important lesson for MTK LK: do not
guess the boot image fields. For MSM8909 LK the target project is explicit
(`project/msm8909.mk` in the LK sources):

```text
BASE_ADDR       0x80000000
kernel          0x80008000   (ABOOT_FORCE_KERNEL_ADDR)
ramdisk         0x82000000   (ABOOT_FORCE_RAMDISK_ADDR)
tags            0x81e00000   (ABOOT_FORCE_TAGS_ADDR)
scratch         0x90100000
```

`ABOOT_IGNORE_BOOT_HEADER_ADDRS=1` is set for this target, so LK overwrites the
kernel/ramdisk/tags addresses from the image header with the values above. The
header still has to describe them consistently, and its page size still drives
how LK walks the image, so the device configuration uses the same values.

The kernel payload is a raw `u-boot-dtb.bin`, not an ARM64 `Image` and not a
gzipped kernel. MSM8909 is a 32-bit Cortex-A7 SoC; a 4 KiB ARM64 Image header
would make LK think it is loading an AArch64 kernel. LK loads raw payloads
without decompressing them, so no compression is used.

## Why U-Boot proper

Like MSM8998, this is not an lk2nd target in this repository. The stock LK can
chainload U-Boot from the `boot` partition, and `fastboot boot` lets us try a
new build without writing that partition.

The second stage keeps the stock first stage in place. Nothing here can restore
the stock boot image by itself because the dev loader has no storage backend.

## What the SoC patch does

| Patch | What it adds |
|-------|--------------|
| `0101` | ARMv7 MSM8909 machine, stub GCC binding, Snapdragon LMB ceiling |

U-Boot's existing `ARCH_SNAPDRAGON` selects `ARM64`, which is unusable here:
MSM8909 is four Cortex-A7 cores and has no AArch64 mode. The patch therefore
adds a small `ARCH_MSM8909` ARMv7 machine. LK already initialized DRAM and the
debug UART, so the machine directory needs no early code; the board file only
publishes the memory map.

MSM8909's GCC has the same register layout as MSM8916 for the clocks this
loader needs (BLSP1 AHB, UART2, USB HS AHB/system). The U-Boot clock provider
is still only used for bookkeeping; the USB path programs the GCC registers
directly in the board hook (see below).

The USB block is the ChipIdea HS OTG plus the integrated ULPI PHY, described
by the `qcom,usb-hs-phy-msm8916` node in the board DTS. `fastboot boot` jumps
to the payload with LK's USB clocks and PHY still running, so the board hook
keeps that state. A normal boot from a flashed `boot` partition runs
`target_usb_exit()` first; the board then votes GPLL0, programs the USB HS
system clock to 80 MHz, enables the USB AHB/system and PHY-sleep gates, pulses
the USB and USB2A PHY resets, and the PHY driver writes the ULPI init sequence.

The boot-mode decision uses the IMEM restart reason (`0x77665500` for LK's
fastboot). Do not probe GCC on the fastboot path: a non-secure access to the
GCC block locks up the interconnect hard enough that the APCS watchdog cannot
recover the board.

## Build

```sh
global/harness/2ndstage/scripts/build.sh \
    --soc device/archos/ac50fhe/harness/2ndstage.conf
# -> .bootloader/build-msm8909/gkiw-2ndstage-ac50fhe.img
#    .bootloader/build-msm8909/u-boot-dtb.bin
```

The build starts from the `gkiw-msm8909_defconfig` ARMv7 target added by the
MSM8909/Archos patches, applies the global patches, and wraps
`u-boot-dtb.bin` as a raw kernel in a v0 Android boot image.

`CONFIG_TEXT_BASE` is `0x80008000`, matching LK's forced kernel load address.
The early stack is just below it at `0x8007fff0`, so it does not overlap the
payload.

## Packaging

| Field | Value |
|-------|-------|
| header | v0 |
| page size | 2048 |
| base | `0x80000000` |
| kernel offset | `0x00008000` |
| ramdisk offset | `0x02000000` |
| second offset | `0x00f00000` |
| tags offset | `0x01e00000` |
| compression | none (raw `u-boot-dtb.bin`) |
| ramdisk | minimal gzip cpio, because some LK builds reject a zero-size one |
| device tree | QCDT v3 table in the old `dt_size` section, entry `245/0x0901000b/9/0x00020000` |

`fastboot boot` does not use the separate `dt` partition, and an uncompressed
raw kernel has no valid appended-DTB offset at `0x2c`, so the DTB must be in a
QCDT table. The entry matches what the stock LK reports for this board:

```text
platform_id 245 (MSM8909), variant_id 0x0901000b,
board_hw_subtype 9, soc_rev 0x00020000, pmic_rev 0..3 = 0
```

`mkbootimg.sh` builds this table from the `GKIW_QCDT_*` variables and sets the
v0 header's last field (the downstream `dt_size`) to its size. The table is
appended after the ramdisk/second sections.

The image can be booted without writing anything, or flashed to `boot`. In the
latter case LK boots it through its normal path and U-Boot initialises the USB
clocks and PHY itself:

```sh
fastboot boot .bootloader/build-msm8909/gkiw-2ndstage-ac50fhe.img
# or, after saving the stock boot image:
fastboot flash boot .bootloader/build-msm8909/gkiw-2ndstage-ac50fhe.img
```

## Memory map

The phone has 2 GiB of DRAM starting at `0x80000000` (`MemTotal` reports about 1.9 GiB). U-Boot is told about all
of it in its internal DTB, but its usable top is capped below the windows it
must not overwrite:

| Region | Address | Size | Notes |
|--------|---------|------|-------|
| fastboot download buffer | `0x90000000` | 128 MiB | reserved in LMB |
| U-Boot ceiling | below `0x9f000000` | — | `board_get_usable_ram_top()` |
| Linux pstore (ramoops) | `0x9f000000` | 1 MiB | `no-map`, survives reset |
| 2ndstage console log | `0x9f100000` | 128 KiB | two 64 KiB slots |

The stock LK puts its own fastboot scratch buffer at `0x90100000`; that memory
is free once U-Boot runs. The pstore/log pair is high enough to stay out of the
stock reserved regions (modem/adsp at `0x88000000`, splash at `0x83000000`).

The Linux DT in a later boot image must reserve the pstore and log regions with
`no-map`, and its ramoops sizes must match `gkiw-msm8909.config`:

```dts
reserved-memory {
    ramoops@9f000000 {
        compatible = "ramoops";
        reg = <0x0 0x9f000000 0x0 0x100000>;
        record-size = <0x20000>;
        console-size = <0x60000>;
        ftrace-size = <0x20000>;
        pmsg-size = <0x20000>;
        ecc-size = <16>;
        no-map;
    };

    gkiw_log: gkiw-log@9f100000 {
        reg = <0x0 0x9f100000 0x0 0x20000>;
        no-map;
    };
};
```

Read them back with the host helper, passing the MSM8909 addresses explicitly:

```sh
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x9f000000 --size 0x100000 -o pstore.bin
global/harness/2ndstage/host/gkiw-fastboot log \
    --addr 0x9f100000 --size 0x20000
```

## Watchdog and reset

The APCS watchdog at `0xb017000` is described as a `qcom,kpss-wdt`. Its tick
clock is a fixed 32.768 kHz (the sleep clock), which gives a hard ceiling of
about 32 s (`0xfffff` ticks). `CONFIG_GKIW_WDT_TIMEOUT_MS=15000` stays below it.

`arch_cpu_init()` arms the APCS watchdog directly for 25 s so a hung early
bring-up comes back on its own. `CONFIG_WATCHDOG_AUTOSTART` is off, and
`board_late_init()` disarms that early arm once fastboot is about to start, so
the fastboot session persists indefinitely.

`CONFIG_SYSRESET_WATCHDOG_AUTO` registers the watchdog as the sysreset device,
so U-Boot's `reset` (used by `fastboot reboot`) expires the watchdog instead of
relying on PSCI.

`fastboot_preboot()` arms both the APCS watchdog (30 s) and the PMIC PON
watchdog (60 s, warm reset). The PMIC watchdog is independent of the APCS and
is taken over by Linux's `pm8916_wdt` driver, which pings it; a hung kernel
therefore resets even when the APCS arm does not survive the kernel. The PMIC
backlight LPG is switched off in `board_late_init()` as well.

`fastboot_set_reboot_flag()` still writes the stock LK restart reason
`0x77665500` to IMEM `0x0860065c`, but the AC50FHE LK ignores it:
`fastboot reboot-bootloader` resets and boots `boot` again. LK fastboot is
reached with the hardware key combo (or `adb reboot bootloader` when Android is
installed).

## Hardware

| Item | Value |
|------|-------|
| SoC | MSM8909, 4x Cortex-A7, 32-bit only |
| debug UART | BLSP1 UART2 at `0x78b0000`, 115200 |
| USB controller | ChipIdea HS OTG at `0x78d9000` |
| USB PHY | integrated ULPI PHY (`qcom,usb-hs-phy-msm8916`) |
| watchdog | APCS at `0xb017000`, 32.768 kHz |
| DRAM | `0x80000000`, 2 GiB |

The UART is intentionally a no-op in U-Boot: the first MSM UART register access
hangs this board after LK hands over, so the USB fastboot transport is the
console. The DTS still carries `clock-frequency = <7372800>` for completeness.

## Use

From the stock fastboot:

```sh
fastboot boot .bootloader/build-msm8909/gkiw-2ndstage-ac50fhe.img
# or, if the stock boot image has been saved:
fastboot flash boot .bootloader/build-msm8909/gkiw-2ndstage-ac50fhe.img
```

Once the U-Boot fastboot enumerates:

```sh
global/harness/2ndstage/host/gkiw-fastboot boot linux-boot.img
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x9f000000 --size 0x100000 -o pstore.bin
```

`fastboot reboot-bootloader` does not reach this LK build; use the hardware key
combo to get back to stock fastboot.

## Unverified

- Booting a Linux image through U-Boot's fastboot is the next milestone.
- The watchdog is not re-armed yet for a Linux payload beyond the existing
  `fastboot_preboot()` hook.
- No storage, display or PMIC support.
