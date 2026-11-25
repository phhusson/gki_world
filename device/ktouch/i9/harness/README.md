# K-Touch i9 second-stage harness

This is the board data for the gki_world development bootloader on the
K-Touch i9 (also sold as Anica i9), a MediaTek MT6739 phone.

The mechanism is shared: see
[`global/harness/2ndstage/README.md`](../../../../global/harness/2ndstage/README.md).
This directory only carries what is specific to this phone.

## What the port adds

- `soc/mediatek/mt6739/harness/patches/0100-mt6739-soc-support.patch`:
  a minimal U-Boot MT6739 target (ARM64, mach-mediatek, generic timer, MTK
  UART, MTK TOPRGU watchdog) and a MUSB peripheral glue for the MT6739
  `mediatek,mt6739-usb20` controller.
- `patches/0101-ktouch-i9-board.patch`: the minimal U-Boot devicetree, the
  defconfig and the board hooks.
- `2ndstage.conf`: addresses, patch directories and host-helper defaults.

The stock first stage (MTK preloader + LK) still owns DDR, the PSCI monitor,
the UART pinmux and the USB PHY power rails. U-Boot does not reinitialise any
of them.

## Build

```sh
global/harness/2ndstage/scripts/build.sh \
    --soc device/ktouch/i9/harness/2ndstage.conf
# -> .bootloader/build-ktouch-i9/gkiw-2ndstage-flash.img
#    .bootloader/build-ktouch-i9/u-boot.bin
```

## Flash and use

The first stage must be unlocked and must accept an unsigned boot image. On
most MTK phones that means an unlocked bootloader and either:

```sh
fastboot flash boot gkiw-2ndstage-flash.img
```

Do **not** use `fastboot boot` on this LK: it rejects the image with
`invalid ramdisk address: not lie in memory` because its fastboot download
buffer overlaps the stock ramdisk address. The same image flashes and boots
through the `boot` partition.

After the 2ndstage enumerates:

```sh
global/harness/2ndstage/host/gkiw-fastboot boot boot.img

# after a crash or watchdog reset
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x5c000000 --size 0x100000 -o pstore.bin
global/harness/2ndstage/host/gkiw-fastboot log \
    --addr 0x5c100000 --size 0x20000
```

The UART console is UART0 at `0x11002000`, 921600 8N1, on the phone's debug
pads. The pinmux is inherited from LK; do not add a UART pinctrl node to the
U-Boot or Linux devicetree.

## Memory map

The phone has at least 2 GiB of RAM, but the development bootloader keeps the
same 512 MiB floor as the other gki_world targets.

| Region | Address | Notes |
|--------|---------|-------|
| 2ndstage image | `0x40078000` base | Android v0 header, LK loads at +0x8000 |
| 2ndstage payload | `0x40080000..0x40081000` | ARM64 Image header, branches to U-Boot |
| U-Boot | `0x40081000..~0x41000000` | text, BSS, heap slack |
| vendor LK reserved | `0x44400000..0x44500000` | avoid: ram_console/pstore/minirdump |
| Linux kernel | `0x45000000` | `base + 0x05000000`, up to 80 MiB |
| ramdisk | `0x4a000000` | `base + 0x0a000000`, up to 80 MiB |
| Linux DTB | `0x4f000000` | `base + 0x0f000000` |
| tags | `0x44000000` | stock tags address |
| fastboot buffer | `0x50000000..0x58000000` | 128 MiB |
| Linux pstore | `0x5c000000..0x5c100000` | 1 MiB, `no-map` |
| 2ndstage log | `0x5c100000..0x5c120000` | 128 KiB, two slots |
| U-Boot malloc/stack | `0x5f000000..0x60000000` | top of the 512 MiB floor |

The Linux devicetree must reserve both `0x5c000000..0x5c100000` as `ramoops`
and `0x5c100000..0x5c120000` as the 2ndstage log, and must keep CMA away from
them:

```dts
reserved-memory {
    ramoops@5c000000 {
        compatible = "ramoops";
        reg = <0x0 0x5c000000 0x0 0x00100000>;
        record-size = <0x20000>;
        console-size = <0x80000>;
        pmsg-size = <0x10000>;
        ftrace-size = <0x10000>;
        no-map;
    };

    gkiw-log@5c100000 {
        reg = <0x0 0x5c100000 0x0 0x00020000>;
        no-map;
    };
};
```

## Watchdog

The MT6739 TOPRGU is a 16-bit counter at 32768 Hz, so the maximum timeout is
about 16 seconds. `CONFIG_GKIW_WDT_TIMEOUT_MS=15000` is set in
`soc/mediatek/mt6739/harness/gkiw-mt6739.config`; do not reuse the G12A 60 s
value. Linux must take over the watchdog within that window or the phone
resets, which is the intended recovery path.

During bringup, **U-Boot must not service the watchdog**. The MT6739 fragment
therefore has:

```text
# CONFIG_WATCHDOG is not set
CONFIG_WATCHDOG_AUTOSTART=y
CONFIG_WATCHDOG_TIMEOUT_MSECS=15000
```

U-Boot starts the timer at init but never pets it, so a hang in MUSB/PHY or
fastboot initialization resets the phone instead of hanging silently. Once
`fastboot devices` shows the phone, switch to `CONFIG_WATCHDOG=y` so U-Boot can
sit in fastboot indefinitely. Until then, use `gkiw watchdog off` over UART if
you need more than 15 s at the prompt.

### Fastboot serial and backlight

U-Boot reads the MTK efuse **HRID** from the DTB that LK leaves at
`tags_addr` (`0x44000000`) under `/chosen/atag,devinfo` and exposes it as the
fastboot `serial#`. If the property is missing it falls back to
`0123456789ABCDEF`.

Once the fastboot receive loop is reached, U-Boot disables `DISP_PWM0`
(`0x1100e000`) to turn the backlight off while waiting.

### Blind boot progress

`CONFIG_GKIW_BRINGUP_BEACONS=y` encodes progress in the watchdog timeout, since
the phone has no console. The reset interval is roughly the first-stage time
(~12 s) plus one of:

| Timeout | Meaning |
|---------|---------|
| 4 s | reached `board_late_init`, hung before the USB probe |
| 8 s | hung inside MUSB/PHY initialization |
| 10 s | USB probe returned an error |
| 12 s | USB probe succeeded and U-Boot reached the fastboot loop |
| 15 s | hung before `board_late_init`, or LK never started U-Boot |

A 27 s loop with the 15 s timeout is therefore "U-Boot not reached (or failed
before late init)", while ~24 s means the MUSB driver probed but the host still
does not enumerate it.

## Limitations and next steps

- **First-stage signature checks.** If the stock preloader/LK verifies the
  `boot` partition, the 2ndstage cannot be flashed without an unlock exploit.
  This port assumes an unlocked bootloader, like the other gki_world harnesses.
- **Boot image contract.** The layout is copied from the Lineage/TWRP
  `recovery.img`, not guessed: base `0x40078000`, kernel `0x40080000`,
  gzip-compressed `Image.gz`, `bootopt=64S3,32N2,64N2`, tags `0x44000000`,
  `second` empty. Stock `Image.gz` carries the DTB **after** the gzip stream;
  the 2ndstage appends the **device DTB** the same way, sets a small dummy
  ramdisk (address `0x45000000`) and a non-zero `second_addr` (`0x40f00000`)
  because this LK validates those fields. Use the stock/Lineage DTB, not
  `u-boot.dtb`: LK applies dconfig/DTBO overlays to it before jumping. Keep the
  kernel at `0x40080000` and link U-Boot at `0x40081000`. Changing any of these
  without checking the stock image reproduces "bootlogo then nothing".

  Extract the DTB and build with it:

  ```sh
  global/harness/2ndstage/scripts/extract-dtb.sh recovery.img stock.dtb
  GKIW_BOOTIMG_DTB=$PWD/stock.dtb \
      global/harness/2ndstage/scripts/build.sh \
      --soc device/ktouch/i9/harness/2ndstage.conf
  ```

  ### Why the kernel section is padded

  This LK resets during `md1img` modem verification when the boot image loads
  too quickly. The expdb shows the normal small boot image reaching `md1img`
  at ~6.3 s and hitting the watchdog, while a 22 MiB recovery image reaches it
  at ~16.5 s and gets through. `GKIW_BOOTIMG_KERNEL_PAD_SIZE` pads the kernel
  section with zeros after the gzip stream (before the appended DTB) so the
  eMMC read takes the same time as the recovery image. The ramdisk stays tiny,
  so the mblock layout does not change and does not trigger
  `reserved_memory_conflict_check`.

  Use `fastboot flash boot`, not `fastboot boot`, for this padded image.
- **USB clocks and UDC mode.** The glue enables the INFRA_AO `infra_icusb`
  gate and selects `univpll3_d4` on `usb_top_sel` directly, because U-Boot has
  no MT6739 clock driver yet. `CONFIG_DM_USB_GADGET` must stay **off**: the
  MUSB gadget core uses its legacy registration path, and `musb_register()`
  returns `-EINVAL` when the DM UDC core is enabled. The PHY/PMIC rails are
  still inherited from LK. The PHY port is at block base + `0x800`
  (`0x11cc0800`), matching the mainline `usb-phy@800` child node.
- **No MMC/SD, network or display.** This is a development payload, not a
  bootloader: it cannot flash itself or restore the stock image.
- **Linux device tree.** The Linux side of the MT6739 port is not part of this
  harness change. The 2ndstage can boot a kernel image, but a mainline
  `mt6739.dtsi`, clock/pinctrl and USB support are still needed before that
  kernel reaches userspace. The `bootimg.yaml` here fixes the image layout the
  kernel must use.
