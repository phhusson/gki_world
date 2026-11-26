# MSM8998 second-stage bootloader

Development-only second stage for Qualcomm Snapdragon 835 phones.  The first
board is the F(x)tec Pro1 (`QX1000`, msm8998); the device layer is
`device/fxtec/pro1`.

The mechanism is the shared one in `global/harness/2ndstage/`.  This directory
adds the Qualcomm board data and the small U-Boot driver/board pieces that
upstream does not have.

## Boot chain

ABL is the first stage.  It loads an Android boot image from the `boot`
partition and jumps to its kernel payload.  The Pro1 accepts header v1 with
4096-byte pages; the kernel is a gzipped `u-boot-nodtb.bin` with `u-boot.dtb`
appended, exactly the shape ABL expects for a Linux `Image.gz-dtb`.

Unlike most older Qualcomm phones, MSM8998 is not supported by lk2nd.  This
layer therefore uses U-Boot proper in the place of the kernel, not an lk2nd
first stage.

## Provenance

The MSM8998 SoC tree and the F(x)tec Pro1 board tree are already in upstream
U-Boot at the pinned commit.  The patches here add only what the harness needs:

| Patch | What it adds |
|-------|--------------|
| `0101` | Match `qcom,gcc-msm8998` against the stub clock driver |
| `0102` | MSM8998 QUSB2 PHY layout/table/config, optional reset, PLL override |
| `0104` | `gkiw-msm8998` board file, env, U-Boot DTS overlay, LMB limit (device layer) |

`0102` is adapted from the Linux `phy-qcom-qusb2.c` driver (GPL-2.0), which is
the only source for the MSM8998 register layout and init table.

### The missing GCC clock driver

U-Boot has no MSM8998 GCC clock/reset driver.  A full driver is a separate
project; this loader only needs the UART and USB clocks that ABL already left
running.  `0101` therefore treats the GCC as a **stub clock provider**:

- `clk_get_by_name()` succeeds for the UART and USB nodes;
- `clk_set_rate()` returns the requested rate;
- `clk_enable()` is a no-op, so nothing is actually gated on.

This is a development shortcut, not a correct clock driver.  If ABL turns a
needed clock off on a particular boot path, UART or USB will fail.  The real
fix is a U-Boot `clock-msm8998.c`.  The same gap is why the QUSB2 reset is
optional: the reset provider would also be the GCC.

The USB glue node's `power-domains` and `resets` phandles are deleted in the
U-Boot overlay.  The GCC stub is not a power-domain or reset provider, and the
DWC3 wrapper aborts the whole probe when the reset lookup fails.  ABL leaves
the controller powered and out of reset, so the loader only needs the clocks
and the QUSB2 PHY.

## Build

```sh
global/harness/2ndstage/scripts/build.sh \
    --soc soc/qcom/msm8998/harness/2ndstage.conf
# -> .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
#    .bootloader/build-msm8998/u-boot-nodtb.bin
```

The build starts from `qcom_defconfig`, merges `qcom-phone.config`, then
`gkiw-msm8998.config`, applies the global gkiw patches and the three SoC
patches, and packages the result.

Verified in this repository with `aarch64-linux-gnu-gcc` 15.2 and `mkbootimg`
34: the config resolves, the DTB builds, `u-boot-nodtb.bin` links, and the
packed image is header v1, page 4096, gzip + appended DTB.  No Pro1 hardware
was available, so **nothing here has been booted**.

## Packaging

`gkiw-2ndstage-pro1.img` matches the stock boot image layout:

| Field | Value |
|-------|-------|
| header | v1 |
| page size | 4096 |
| base | `0x00000000` |
| kernel offset | `0x00008000` |
| ramdisk offset | `0x01000000` |
| second offset | `0x00f00000` |
| tags offset | `0x00000100` |
| OS | 9.0.0 / 2020-04 |

The kernel payload is `gzip -n u-boot-nodtb.bin` followed by `u-boot.dtb`.
The build script does this through `GKIW_BOOTIMG_COMPRESS=gzip` and
`GKIW_BOOTIMG_APPEND_DTB=1`; the build passes `u-boot.dtb` as the DTB to
append.

The image is padded to 64 MiB (`GKIW_BOOTIMG_IMAGE_PAD_SIZE=0x4000000`).  This is
not cosmetic: the stock boot partition is 64 MiB and its stock image has an
AVB footer at the very end, with the embedded vbmeta at `0x1534000`.  Writing
a smaller unsigned image leaves the old footer and hash in place, so ABL
verifies the old hash against the new payload and falls back to fastboot.
The padded image overwrites both with zeros.  If the device still enforces
AVB, verification has to be disabled on the `vbmeta` partition (or the
bootloader unlocked); padding alone cannot replace the OEM signature.

The stock `dtbo.img` is an 8 MiB signed overlay for the downstream QRD tree.
Erase the active slot's dtbo before booting U-Boot; it is not compatible with
the mainline/U-Boot DTB and is what the postmarketOS Pro1 port erases.

Flash `gkiw-2ndstage-pro1.img` to the `boot` partition in ABL fastboot mode:

```sh
fastboot flash boot .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
# or, to try without writing:
fastboot boot .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
```

Keep a copy of the stock `boot.img`.  This loader has no storage backend, so it
cannot restore the stock boot chain by itself.

## Memory map

The Pro1 has 6 GiB of DRAM.  ABL fills the size of the `/memory` node in the
appended DTB; U-Boot reads the map from there.  The harness uses:

| Region | Address | Size | Notes |
|--------|---------|------|-------|
| ABL framebuffer | `0x9d600000`..`0x9fa00000` | 36 MiB | `cont_splash_mem` |
| fastboot buffer | `0xa0000000`..`0xa8000000` | 128 MiB | reserved in LMB |
| Linux pstore (ramoops) | `0xffc00000`..`0xffd00000` | 1 MiB | `no-map` |
| 2ndstage console log | `0xffd00000`..`0xffd20000` | 128 KiB | two 64 KiB slots |
| U-Boot ceiling | below `0xffc00000` | — | pulled below pstore |

`board_get_usable_ram_top()` walks `/reserved-memory` and stops U-Boot below
any window it would otherwise erase.  `LMB_LIMIT_DMA_BELOW_RAM_TOP` is made
default for Snapdragon so `bootm` also keeps the kernel and ramdisk below the
ceiling.  The fastboot buffer is reserved with
`lmb_alloc_mem(LMB_MEM_ALLOC_ADDR)`, so `bootm` cannot reuse the downloaded
image's memory.

## Hardware

| Item | Value |
|------|-------|
| SoC | MSM8998 v2/v2.1 |
| debug UART | `0xc1b0000`, 115200 |
| USB controller | DWC3 at `0xa800000`, glue at `0xa8f8800` |
| USB PHY | QUSB2 at `0xc012000` |
| USB mode | peripheral only, high speed |
| framebuffer | `0x9d600000`, 1080x2160, stride 1080*4 |
| pstore | `0xffc00000`, 1 MiB |

The UART node carries `clock-frequency = <19200000>` because the GCC is a
stub.  ABL normally leaves BLSP2 UART1 on the 19.2 MHz XO.  If the console is
garbled, the first thing to try is another rate (24 MHz or 115.2 MHz); the
second is a real GCC driver.

USB is described as USB2 only: the QMP USB3 PHY has no U-Boot driver, and the
DWC3 node is changed to use `qusb2phy` alone with
`maximum-speed = "high-speed"`.  This is the same choice the OnePlus MSM8998
trees make.

The framebuffer is the region ABL leaves behind.  There are no clock or
power-domain phandles on it; ABL already turned the display on, and U-Boot has
no MSM8998 display clock driver.  The console is on the panel through
`vidconsole`, with the UART as the first output.

## Linux device-tree contract

The boot image's DT must reserve the pstore and 2ndstage log regions:

```dts
reserved-memory {
    ramoops@ffc00000 {
        compatible = "ramoops";
        reg = <0x0 0xffc00000 0x0 0x100000>;
        console-size = <0x60000>;
        record-size = <0x10000>;
        ftrace-size = <0x10000>;
        pmsg-size = <0x20000>;
        ecc-size = <16>;
        no-map;
    };

    gkiw_log: gkiw-log@ffd00000 {
        reg = <0x0 0xffd00000 0x0 0x20000>;
        no-map;
    };
};
```

The `CONFIG_CMD_PSTORE_*` sizes in `gkiw-msm8998.config` match these values.
The host helper's defaults are the Amlogic map, so pass the Pro1 addresses:

```sh
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0xffc00000 --size 0x100000 -o pstore.bin
global/harness/2ndstage/host/gkiw-fastboot log \
    --addr 0xffd00000 --size 0x20000
```

## Use

From the Pro1's ABL fastboot:

```sh
fastboot boot .bootloader/build-msm8998/gkiw-2ndstage-pro1.img
```

Once the second stage enumerates:

```sh
global/harness/2ndstage/host/gkiw-fastboot boot linux-boot.img
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0xffc00000 --size 0x100000 -o pstore.bin
```

`fastboot reboot-bootloader` writes `0x77665500` to the MSM8998 IMEM restart
reason at `0x146bf65c` and resets.  ABL reads that value on the next boot and
enters its own fastboot, without needing the BCB or UFS.  `fastboot
reboot-fastboot` writes the same value; `fastboot reboot-recovery` writes the
recovery value.  A plain `fastboot reboot` does not write a reason, so ABL
boots the flashed 2ndstage image again.

The second stage has no storage backend, so `fastboot flash` is not available
from it.

## Blocked and unverified

- **Hardware status.**  U-Boot boot, display output and USB fastboot are
  verified on a Pro1.  Pstore readback, `reboot-bootloader` to ABL and booting
  a Linux image are not yet verified.
- **No real GCC clock driver.**  The stub relies on ABL leaving the UART and
  USB clocks enabled; the 19.2 MHz UART rate is an assumption.
- **QUSB2 reset is skipped.**  The reset provider would be the missing GCC
  driver.  ABL is assumed to leave the PHY out of reset.
- **No watchdog node.**  MSM8998's DTS has no `qcom,kpss-wdt` node in this
  tree, so `gkiw watchdog` reports the missing device.
- **No USB3.**  The QMP USB3 PHY is disabled; only USB2 high speed is used.
- **No storage, PCIe or PMIC.**  They are disabled on purpose.  `fastboot
  flash` and UFS/SD access are not available.
- **Framebuffer geometry.**  The address comes from the stock DTB and the
  panel does show output, but the geometry is not tuned yet.  If the console is
  rotated, stretched or offset, adjust the `framebuffer@9d600000` node.
- **No Linux port.**  The Pro1 mainline DT exists, but the Linux side of this
  device is out of scope here.
