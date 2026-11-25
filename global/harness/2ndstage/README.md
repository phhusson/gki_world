# Second-stage bootloader

A development-only bootloader that shortens the edit/build/boot loop:

- UART console, 115200.
- One USB gadget function: Android fastboot over the SoC's DWC2 peripheral.
- `fastboot boot` accepts an Android boot image (kernel + ramdisk + DTB).
- `fastboot oem pstore:<addr>:<size>` streams a RAM region (pstore/ramoops from
  the previous boot) back to the host.
- Immediately before booting, it arms the hardware watchdog for 60 seconds, so a
  hung Linux resets the board instead of hanging the loop.

It is not part of a device's shipped stack and it is not a general-purpose
bootloader. It exists to make kernel bringup fast.

## Why U-Boot, and why a thin fork

U-Boot already has everything this needs for Amlogic G12A: Meson DDR/clock/
pinctrl init, the DWC2 peripheral driver, the fastboot gadget, Android boot
image parsing, and a Meson watchdog driver. Writing a custom bootloader means
reimplementing all of that before the first kernel boots.

The fork is deliberately thin:

```text
pinned U-Boot commit + 3 small changes
  - gkiw command: pstore hex dump and watchdog control (UART)
  - fastboot oem pstore: multiresponse chunked RAM read
  - fastboot preboot hook: arm the watchdog before bootm
```

Nothing else is forked. Rebase by bumping `uboot.conf` and refreshing the
patches; the build script applies them to a clean tree every time.

The mechanism lives here (`global/`), the board data lives in the SoC layer
(`soc/amlogic/g12a/harness/`). A second Amlogic SoC or board adds data, not a
second bootloader.

## Transport

Only UART and the fastboot gadget. U-Boot's USB gadget stack is single-function,
so there is no composite ACM+fastboot device. The UART is the console; USB is
the control and data channel.

| Need | Mechanism |
|------|-----------|
| boot a kernel | `fastboot boot boot.img` |
| read pstore | `fastboot oem pstore:<addr>:<size>` |
| reset on hang | watchdog armed in `fastboot_preboot()` |
| manual watchdog | `gkiw watchdog [ms\|off]` on the UART |

`oem pstore` uses U-Boot's multiresponse machinery: the device sends `INFO`
lines of `<offset>:<hex>`, 24 bytes per line, then `OKAY`. The stock `fastboot`
client prints them as `(bootloader) ...`; `host/gkiw-fastboot` reassembles them.
No custom USB protocol and no patched host tool.

## Pstore contract

The bootloader does not parse the device tree. The host passes the ramoops
address and size explicitly, so the same binary works with any DT:

```sh
host/gkiw-fastboot pstore --addr 0x3f000000 --size 0x100000 -o pstore.bin
```

The DT used for the next boot must reserve the same region:

```dts
reserved-memory {
    ramoops@3f000000 {
        compatible = "ramoops";
        reg = <0 0x3f000000 0 0x100000>;
        record-size = <0x20000>;
        console-size = <0x80000>;
        no-map;
    };
};
```

The region must survive the first-stage bootloader. On G12A the vendor first
stage initializes DDR and does not scrub RAM, so the data survives a reset. Keep
the region disjoint from U-Boot's own memory: the fastboot buffer is
`0x21000000..0x31000000` in the prototype, and the stack is at `0x20000000`.

## Watchdog

`fastboot_preboot()` arms the first watchdog device for 60 seconds before
`bootm`. Linux's `meson_gxbb_wdt` driver then takes over and pets it; if Linux
hangs before that, the board resets. The Meson counter is 16-bit at 1 ms, so the
maximum is about 65 seconds.

This is the intended behaviour for the development loop: a kernel that panics or
wedges comes back on its own. For a boot that must not be interrupted, use
`gkiw watchdog off` from the UART before booting.

## Build

```sh
global/harness/2ndstage/scripts/build.sh
# -> .bootloader/build-g12a/u-boot.bin
```

Requirements: `aarch64-linux-gnu-gcc`, and the usual U-Boot host tools
(`bison`, `flex`, `swig`, Python). The script disables U-Boot's host signing
tools because this image boots unsigned images and because OpenSSL 4 removed the
ENGINE API those tools still use.

The source tree (`.bootloader/u-boot`) is managed: every run resets it to
`uboot.conf`'s pinned commit and reapplies the patches.

Board data:

```text
soc/amlogic/g12a/harness/2ndstage.conf    # base defconfig, fragment, defaults
soc/amlogic/g12a/harness/gkiw-g12a.config # UART + fastboot + watchdog + gkiw
```

The base is `u200_defconfig`, the S905X2 reference board. A retail S905X2 box
usually needs its own U-Boot DTS (eMMC, DDR, USB port, Ethernet) but not a new
build of the gkiw patches.

## Use

```sh
# boot a kernel + DT + initramfs packed as an Android boot image
global/harness/2ndstage/host/gkiw-fastboot boot boot.img

# after it crashes/resets, pull the previous boot's pstore
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x3f000000 --size 0x100000 -o pstore.bin
```

`fastboot` must be in `PATH`; override with `FASTBOOT=/path/to/fastboot`.

## Limitations and footguns

- **Signed boot chains.** Many retail Amlogic boxes verify the bootloader. If
  the first stage cannot be replaced or put in burn mode, this approach does not
  apply. The U200 reference board is the easy path.
- **Board DTS.** The U200 tree is not a universal S905X2 tree. Getting the USB
  peripheral port and the eMMC right per board is expected.
- **Pstore is best-effort.** If the first stage clears the reserved region, or
  the DT does not reserve it as `no-map`, there is nothing to read.
- **Watchdog size.** 60 s is the prototype default; the hardware cannot go much
  beyond 65 s.
- **Android boot image only.** `fastboot boot` goes through U-Boot's Android
  image parser. Pack kernel/DT/initramfs with `mkbootimg`, not as raw files.
- **Arbitrary RAM read.** `oem pstore` reads any address the host asks for. It
  is a development tool: never ship it, never leave it reachable on a device you
  do not control.
