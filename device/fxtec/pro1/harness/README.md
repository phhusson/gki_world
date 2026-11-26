# F(x)tec Pro1 (QX1000 / MSM8998) harness notes

This is the original Pro1 with the Snapdragon 835 (MSM8998), codename
`QX1000` / `pro1`.  **Do not flash this on a Pro1-X (QX1050)**: that is an
SM6115/Snapdragon 662 phone with a different boot chain and device tree.

The device currently has only the development second stage.  There is no
mainline Linux config for it in this repository yet, so `bootimg.yaml`
describes the boot image wrapper, not a full Linux port.

## First stage

ABL is the first stage.  It exposes the normal Android fastboot interface:

```sh
fastboot flash boot .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
# or try without writing:
fastboot boot .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
```

The partition is always named `boot`; only the local filename differs.  Keep a
copy of the stock `boot.img` before flashing.  The second stage has no storage
backend, so it cannot restore the stock boot chain by itself.

`gkiw-2ndstage-pro1.img` is gzipped `u-boot-nodtb.bin` with `u-boot.dtb`
appended, in a header-v1 image with 4096-byte pages.  This is the same shape as
the stock Android 9 boot image and the mainline Linux `Image.gz-dtb` the Pro1
already boots.

## If it comes straight back to fastboot

ABL does not support `fastboot boot`; that failure is expected.  If flashing
and rebooting still lands in fastboot:

1. Erase the active slot's stock dtbo overlay.  It targets the downstream QRD
   tree, not the U-Boot DTB, and the postmarketOS Pro1 port erases it too:

   ```sh
   fastboot getvar current-slot
   fastboot erase dtbo_a      # or dtbo_b
   ```

2. The stock boot image is 64 MiB and ends with an AVB footer.  The build pads
   `gkiw-2ndstage-pro1.img` to 64 MiB so the stale footer and its embedded
   vbmeta are overwritten with zeros.  Make sure the new 64 MiB file was
   flashed, not the old small one:

   ```sh
   ls -l .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
   fastboot flash boot .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
   ```

3. If it still returns to fastboot, ABL is still enforcing AVB.  Disable
   verification on the active slot's `vbmeta` (requires an unlocked
   bootloader), or use a disabled vbmeta image.  Keep a copy of the stock
   vbmeta first if the partition is writable.

The stock image has an 8 MiB ramdisk; U-Boot does not need one, so the
2ndstage image has an empty ramdisk.  The kernel/ramdisk/second/tags load
addresses otherwise match the stock header exactly.

## Return to ABL fastboot

From the U-Boot fastboot interface:

```sh
fastboot reboot-bootloader
```

This writes the MSM8998 IMEM restart reason (`0x77665500` at `0x146bf65c`)
and resets.  ABL reads it and enters its own fastboot, so the command takes
you back to the first-stage fastboot without touching the boot partition.

A plain `fastboot reboot` does not write a reason; ABL then boots the flashed
2ndstage image again, which is U-Boot.

## Build

```sh
global/harness/2ndstage/scripts/build.sh \
    --soc soc/qcom/msm8998/harness/2ndstage.conf
# .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
```

## Display and UART

The debug UART is BLSP2 UART1 at `0xc1b0000`, 115200.  ABL configures its
pins; the second stage does not re-apply them.  The physical test points on
the Pro1 have not been located.

The console is also drawn on the ABL framebuffer at `0x9d600000`, 1080x2160,
stride `1080 * 4`.  The address comes from the stock device tree.  If the
text is rotated, mirrored or offset, the first thing to adjust is the
`framebuffer@9d600000` node in the U-Boot DTS overlay.

## Pstore and console log

The second stage reserves and uses:

| Region | Address | Size |
|--------|---------|------|
| Linux pstore (ramoops) | `0xffc00000` | 1 MiB |
| 2ndstage console log | `0xffd00000` | 128 KiB |
| fastboot download buffer | `0xa0000000` | 128 MiB |
| ABL framebuffer | `0x9d600000` | 36 MiB |

The Linux DT in the boot image must reserve the pstore and log regions with
`no-map`, and its ramoops sizes must match
`soc/qcom/msm8998/harness/gkiw-msm8998.config`.  Pass the Pro1 addresses to the
host helper explicitly; its defaults are the Amlogic map:

```sh
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0xffc00000 --size 0x100000 -o pstore.bin
global/harness/2ndstage/host/gkiw-fastboot log \
    --addr 0xffd00000 --size 0x20000
```

U-Boot stops below `0xffc00000`, so a reset does not erase the pstore or the
log it is meant to leave for the next boot.

## Watchdog

The MSM8998 device tree in this U-Boot has no `qcom,kpss-wdt` node, so the
QCOM watchdog driver does not bind.  `gkiw watchdog` reports the missing
device and a hung boot is not guaranteed to reset.  Do not enable a watchdog
in Linux until there is a reliable way back in.

## Still missing

- No hardware run of any kind; see `soc/qcom/msm8998/harness/README.md`.
- No real MSM8998 GCC clock driver; the GCC is a stub and relies on ABL.
- No USB3; USB2 high speed only.
- No UFS/SD storage, so no `fastboot flash` from the second stage.
- No watchdog node and no mainline Linux config for the Pro1 yet.
