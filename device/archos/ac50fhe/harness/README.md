# Archos 50f Helium (AC50FHE / MSM8909) harness notes

This is the 5-inch Archos 50f Helium, codename `ac50fhe`, on Qualcomm MSM8909
(Snapdragon 210, four Cortex-A7 cores, 2 GiB RAM). It is **not** the
`ac50bhe` entry: that one is the MSM8916-based 50b Helium 4G.

The device has only the development second stage in this repository. There is
no mainline Linux device tree or config for it yet.

## First stage

The stock bootloader is Qualcomm LK and exposes the normal Android fastboot
interface (`fastboot devices` shows the serial; `product: MSM8909`).

The development loop does not require flashing:

```sh
global/harness/2ndstage/scripts/build.sh \
    --soc device/archos/ac50fhe/harness/2ndstage.conf
fastboot boot .bootloader/build-msm8909/gkiw-2ndstage-ac50fhe.img
```

The same image can also be flashed to `boot`; LK then boots it through its
normal path and U-Boot brings the USB clocks and ULPI PHY back up itself. The
stock Android boot image is overwritten in that case, so keep a stock
`boot.img` if Android has to be restored later.

The boot image is a v0 Android image with a raw `u-boot-dtb.bin` kernel. LK
forces the kernel to `0x80008000`, the ramdisk to `0x82000000` and the tags to
`0x81e00000` (`ABOOT_IGNORE_BOOT_HEADER_ADDRS`), and MSM8909 has no AArch64
mode, so the payload must not carry an ARM64 Image header.

LK's `fastboot boot` does not consult the separate `dt` partition, and an
uncompressed raw kernel has no valid appended-DTB offset at `0x2c`, so the DTB
travels as a QCDT table in the old `dt_size` field. The matching IDs were
obtained from LK's own failure log (`fastboot oem log`):

```text
platform_id 245 (MSM8909), variant_id 0x0901000b, subtype 9,
soc_rev 0x00020000  (LK log: hw_id=11, platform_subtype=9)
```

This loader has no storage backend and cannot restore the stock boot chain by
itself. Once `boot` has been overwritten, LK fastboot is still available through
the hardware key combo (Volume Down + Power) and can reflash a stock image.

## Return to LK fastboot

This LK build ignores the IMEM restart reason: `fastboot reboot-bootloader`
from U-Boot resets and boots the `boot` partition again, i.e. back into U-Boot.
Use the hardware key combo (Volume Down + Power) to enter LK fastboot, or
`adb reboot bootloader` if Android is still installed.

A plain `fastboot reboot` from U-Boot is a normal reset and comes back into
U-Boot when the image is flashed to `boot`.

## Build

```sh
global/harness/2ndstage/scripts/build.sh \
    --soc device/archos/ac50fhe/harness/2ndstage.conf
# -> .bootloader/build-msm8909/gkiw-2ndstage-ac50fhe.img
#    .bootloader/build-msm8909/u-boot-dtb.bin
```

The base is the ARMv7 `gkiw-msm8909_defconfig` added by this port: U-Boot's
existing `ARCH_SNAPDRAGON` targets are AArch64, which cannot run on this
Cortex-A7 SoC. The MSM8909 fragment adds USB fastboot, pstore and the watchdog;
the device patch adds the board DTS, board hooks, defconfig and env.

## Memory map and host helpers

| Region | Address | Size |
|--------|---------|------|
| fastboot download buffer | `0x90000000` | 128 MiB |
| U-Boot ceiling | below `0x9f000000` | — |
| Linux pstore (ramoops) | `0x9f000000` | 1 MiB |
| 2ndstage console log | `0x9f100000` | 128 KiB |

Pass these addresses explicitly; the host helper's built-in defaults are the
Amlogic map:

```sh
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x9f000000 --size 0x100000 -o pstore.bin
global/harness/2ndstage/host/gkiw-fastboot log \
    --addr 0x9f100000 --size 0x20000
```

The Linux DT in a later boot image must reserve both regions with `no-map`, and
its ramoops sizes must match `soc/qcom/msm8909/harness/gkiw-msm8909.config`.

## Serial number

LK passes the factory serial number in `/chosen/bootargs` as
`androidboot.serialno=`. The QCDT FDT carrying it arrives in `r2`; the ARMv7
start code saves that pointer at `0x90000000`, and `board_late_init()` copies
the serial into U-Boot's `serial#`. `fastboot devices` therefore shows the real
device serial (currently `185904e3`) instead of a fixed placeholder. If the FDT
is missing, the board falls back to a CPU-ID-derived string.

## Hardware notes

- Debug UART: BLSP1 UART2 at `0x78b0000`, 115200 (`ttyHSL0` on the stock
  kernel). LK configures its pins.
- USB: ChipIdea HS OTG at `0x78d9000` with the integrated ULPI PHY
  (`qcom,usb-hs-phy-msm8916`). `fastboot boot` inherits LK's running clocks
  and PHY; a normal boot enables GPLL0, the 80 MHz USB HS system clock, the
  AHB/system/PHY-sleep gates and pulses the USB/PHY resets before probing the
  controller.
- Watchdog: APCS at `0xb017000`, 32.768 kHz. The 15 s timeout is below the
  32 s counter ceiling.
- DRAM: `0x80000000`, 1 GiB.

## Status

USB fastboot works in both boot modes:

- `fastboot boot`: LK leaves its USB clocks and PHY running. U-Boot recognises
  the fastboot restart reason and deliberately keeps that state, because the
  GCC block is not accessible to the non-secure second stage on this path.
- Flashed `boot` + normal reboot: LK runs `target_usb_exit()`, so U-Boot
  enables GPLL0, programs the USB HS system clock to 80 MHz, enables the AHB,
  system and PHY-sleep gates, pulses the USB/PHY resets, writes the ULPI PHY
  init sequence and then starts the fastboot gadget.

The fastboot instance enumerates as `ac50fhe`, survives indefinitely, and
`fastboot reboot` resets through the APCS watchdog and comes back. The
boot-mode decision uses the IMEM restart reason (`0x77665500` for LK's
fastboot), not a register probe: touching GCC on the fastboot path locks up
the interconnect so hard that the watchdog cannot recover it.

Other bring-up findings:

- The MSM UART must not be touched from U-Boot; `serial_msm.c` is a no-op here.
  The first UART register access hangs the board after LK hands over.
- The PHY is ULPI, not the 28 nm Femto PHY. The controller DTS uses the
  `qcom,usb-hs-phy-msm8916` node and the driver writes the vendor init sequence
  `<0x00 0x44, 0x01 0x6b, 0x02 0x24, 0x03 0x13>`.
- The PM8909 LPG/PWM backlight is switched off in `board_late_init()` so a
  long fastboot/bringup session does not drain the battery through the panel.
- The PMIC PON watchdog is armed for 60 s (warm reset) just before booting an
  OS. On Linux, `/init` owns `/dev/watchdog` from userspace and only pings it
  while the host sends heartbeats on the second ACM port, so losing the host or
  the USB link resets the phone back into the second stage.

## Still missing

- Booting a Linux image through U-Boot's fastboot is the next milestone.
- No usable UART console (deliberately not touched).
- No storage, display or PMIC support.
- No mainline Linux device tree or userspace.
