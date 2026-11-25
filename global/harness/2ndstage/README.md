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
pinned U-Boot commit + small patches
  - gkiw command: pstore hex dump, watchdog control, crash log
  - fastboot oem pstore: multiresponse chunked RAM read
  - fastboot preboot hook: arm the watchdog before bootm
  - minimal G12A devicetree: UART, DWC2 gadget, watchdog only
  - 512 MiB floor, no relocation, Amlogic chip serial as fastboot serialno
  - ARM64 exception hook writing the persistent 2ndstage crash log
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

The console pinmux is **inherited from the first stage**. Some S905X2 boxes
route UART over the SD card pads with a special mux; re-applying the reference
board's UART pins changes the RX pad and leaves TX-only output. For those
boards the bootloader and Linux trees must not add a UART pinctrl node.

| Need | Mechanism |
|------|-----------|
| boot a kernel | `fastboot boot boot.img` |
| read pstore | `fastboot oem pstore:<addr>:<size>` |
| read 2ndstage crash log | `gkiw log` or `oem pstore:0x1c100000:0x10000` |
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
host/gkiw-fastboot pstore --addr 0x1c000000 --size 0x100000 -o pstore.bin
```

The DT used for the next boot must reserve the same region:

```dts
reserved-memory {
    ramoops@1c000000 {
        compatible = "ramoops";
        reg = <0 0x1c000000 0 0x100000>;
        record-size = <0x20000>;
        console-size = <0x80000>;
        no-map;
    };
};
```

The region must survive the first-stage bootloader. On G12A the vendor first
stage initializes DDR and does not scrub RAM, so the data survives a reset.

The prototype memory map is part of the contract:

| Region | Address | Notes |
|--------|---------|-------|
| secure world / first stage | `0x00000000..0x08000000` | first 128 MiB, never used for data |
| fastboot buffer | `0x10000000..0x18000000` | 128 MiB |
| Linux pstore | `0x1c000000..0x1c100000` | 1 MiB |
| 2ndstage crash log | `0x1c100000..0x1c200000` | 64 KiB |
| initial stack | `0x20000000` | top of the 512 MiB assumption |

The bootloader assumes **at least 512 MiB of RAM** and does not parse the real
size. On G12A the first stage loads BL33 at `0x01000000`, inside the low 128 MiB;
that cannot be changed from the second stage, but all of its own buffers, pstore
and the Linux-visible memory stay out of that region.

## Simplifications for porting

A development-only second stage can make assumptions a real bootloader cannot.
Porting to another SoC should mostly be a new DTS and a new config fragment:

- assume at least 512 MiB of RAM; never probe the real size;
- treat the first 128 MiB as owned by the secure world / first stage;
- use fixed physical addresses for the fastboot buffer and pstore, documented
  per SoC, all inside the 128–512 MiB window;
- support UART and a USB device port only: no eMMC/SD, network, display, audio,
  PCIe, no boot-from-disk, no environment storage, no partition parsing;
- a single USB function (fastboot), no composite gadget;
- the watchdog is the whole reset policy.

These assumptions are allowed because this image is never shipped and is not a
general-purpose bootloader. They must not leak into kernel drivers or shipping
device configs.

To port: pick a SoC with a usable first stage, write a minimal DTS with UART,
DWC2 (or the SoC's peripheral controller) and the watchdog, put the buffers in
the safe window, and reuse the three generic patches unchanged.

## Watchdog

`fastboot_preboot()` arms the first watchdog device for 60 seconds before
`bootm`. `CONFIG_WATCHDOG=y` makes U-Boot **service** it while it is running:
the fastboot loop calls `schedule()`, which runs the cyclic reset every second.
When U-Boot jumps to Linux the cyclic servicing stops, the hardware timer keeps
running, and Linux must take over within 60 seconds. If it does not, the board
resets. The Meson counter is 16-bit at 1 ms, so the maximum is about 65 seconds.

This is the intended behaviour for the development loop: U-Boot can wait in
fastboot indefinitely, a kernel that panics or wedges comes back on its own, and
a boot that must not be interrupted can use `gkiw watchdog off` from the UART
before booting.

## Second-stage crash log

Before resetting on an ARM64 exception, U-Boot writes a text register dump to a
persistent region outside its BSS/stack/heap and the Linux pstore:

```text
0x1c100000..0x1c200000   64 KiB, CONFIG_GKIW_LOG_ADDR/SIZE
```

The header is `GKLG`, a sequence number and the text length, followed by the
exception reason, `esr`, `elr`, `spsr` and `x0..x30`. It is separate from
ramoops, so a 2ndstage crash does not overwrite a Linux pstore record.

On the next boot:

```sh
# over UART
gkiw log
gkiw log clear

# or from the host, using the same chunked transport
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x1c100000 --size 0x10000 -o 2ndstage-crash.bin
```

The exception hook runs from `show_regs()`, so it captures synchronous aborts,
SErrors and bad-mode exceptions. A plain `panic()` path is not captured yet.

## Build

```sh
global/harness/2ndstage/scripts/build.sh
# -> .bootloader/build-g12a/gkiw-2ndstage-flash.img  (v0, stock first stage)
#    .bootloader/build-g12a/u-boot.bin
```

The v0 image is for the stock first stage. Self-chainloading was dropped: it
needed a second image, a separate DTB and a special `booti` path for very little
gain. `fastboot reboot-bootloader` resets instead; the first stage reloads the
flashed image and comes back here.

`serial#` is derived from the Amlogic secure-monitor chip serial and exposed as
fastboot `serialno`; `board` is set to `gkiw-g12a`, which becomes the fastboot
`product`.

Requirements: `aarch64-linux-gnu-gcc`, `mkbootimg` (AOSP host tools), and the
usual U-Boot host tools (`bison`, `flex`, `swig`, Python). The script disables
U-Boot's host signing tools because this image boots unsigned images and because
OpenSSL 4 removed the ENGINE API those tools still use.

The source tree (`.bootloader/u-boot`) is managed: every run resets it to
`uboot.conf`'s pinned commit and reapplies the patches.

### Boot image

`gkiw-2ndstage-flash.img` is an Android v0 boot image: kernel load address
`0x08000000`, page size 2048, empty ramdisk. The kernel is:

```text
0x08000000 + 0x0000   4 KiB ARM64 Image header, code0 branches to 0x1000
0x08000000 + 0x1000   u-boot-dtb.bin, linked at 0x08001000
```

The header sets flags bit 3 so `booti` respects the load address instead of
relocating the image, and U-Boot is built position-independent so a 4 KiB-aligned
relocation still works. `0x08000000` is deliberately above the low 128 MiB and
away from the vendor DTB at `0x01000000`: loading there overwrites the DTB and
the first stage later fails with `FDT_ERR_BADMAGIC`.

This is a **chainload** image: the stock first stage must boot an Android image
and allow unsigned payloads. It does not replace a signed Amlogic BL2/FIP. If
the first stage loads a raw payload instead, use `u-boot.bin` and make it load
at `0x08001000` (or change `CONFIG_TEXT_BASE`).

The fastboot buffer, pstore and memory assumptions are unchanged; only the
entry address of the payload moves.

If the log says `kernel loaded at 0x01000000` followed by
`libfdt fdt_check_header(): FDT_ERR_BADMAGIC` or `image is not a fdt`, the
kernel load address has collided with the first stage's DTB. Move
`GKIW_BOOTIMG_BASE`, keep `CONFIG_TEXT_BASE` at base + header size, and rebuild.

Board data:

```text
soc/amlogic/g12a/harness/2ndstage.conf    # base defconfig, fragment, defaults
soc/amlogic/g12a/harness/gkiw-g12a.config # UART + fastboot + watchdog + gkiw
```

The base is `u200_defconfig`, the S905X2 reference board. The fragment switches
to the minimal `meson-g12a-gkiw.dts`: only UART, the DWC2 gadget and the
watchdog are enabled. MMC/SD, Ethernet, display, audio, PCIe and the USB3 host
are not enabled, and the matching drivers are trimmed. The shared SoC dtsi
still contains those nodes but leaves them disabled; the board tree never turns
them on.

A retail S905X2 box usually needs its own U-Boot DTS (USB peripheral port, DDR)
but not a new build of the gkiw patches.

## Use

```sh
# once: make the stock first stage chainload the second stage
fastboot flash boot gkiw-2ndstage-flash.img
# (or `fastboot boot` it, if the stock bootloader supports that)

# come back to this second stage after a Linux test or crash
fastboot reboot-bootloader
```

After it enumerates:

```sh
# boot a kernel + DT + initramfs packed as an Android boot image
global/harness/2ndstage/host/gkiw-fastboot boot boot.img

# after it crashes/resets, pull the previous boot's pstore
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x1c000000 --size 0x100000 -o pstore.bin
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
- **No vendor fastboot.** The 2ndstage cannot restore the stock U-Boot. A reset
  goes through the first stage and reloads the flashed `gkiw-2ndstage-flash.img`;
  use the vendor's own key combo/recovery path if you need its fastboot.
- **Arbitrary RAM read.** `oem pstore` reads any address the host asks for. It
  is a development tool: never ship it, never leave it reachable on a device you
  do not control.
