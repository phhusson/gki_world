# Second-stage bootloader

A development-only bootloader that shortens the edit/build/boot loop:

- UART console, target-specific baud (115200 on G12A, 921600 on MT6739).
- One USB gadget function: Android fastboot over the SoC's DWC2 peripheral.
- `fastboot boot` accepts an Android boot image (kernel + ramdisk + DTB).
- `fastboot oem pstore:<addr>:<size>` streams a RAM region (pstore/ramoops from
  the previous boot) back to the host.
- Immediately before booting, it arms the hardware watchdog for a
  target-specific timeout, so a hung Linux resets the board instead of hanging
  the loop.

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
  - gkiw command: pstore hex dump, watchdog control, console log
  - fastboot oem pstore: multiresponse chunked RAM read
  - fastboot preboot hook: arm the watchdog before bootm
  - minimal G12A devicetree: UART, DWC2 gadget, watchdog only
  - 512 MiB floor, no relocation, Amlogic chip serial as fastboot serialno
  - continuous persistent console log, A/B slots, exception register dump
```

Nothing else is forked. Rebase by bumping `uboot.conf` and refreshing the
patches; the build script applies them to a clean tree every time.

The mechanism lives here (`global/`), the board data lives in the SoC layer
(`soc/amlogic/g12a/harness/`) or, for a phone, in its device layer
(`device/ktouch/i9/harness/`). A second SoC or board adds data and,
where U-Boot does not already have it, a small set of SoC support patches; it
does not fork the bootloader.

Patch directories are selected per target:

```text
global/harness/2ndstage/patches/          # mechanism, shared by every SoC
soc/amlogic/g12a/harness/patches/         # G12A devicetree/board hooks
soc/mediatek/mt6739/harness/patches/      # MT6739 mach/board/MUSB support
device/ktouch/i9/harness/patches/         # K-Touch i9 devicetree/defconfig
```

`UBOOT_PATCH_DIRS` in the target's `2ndstage.conf` lists the extra directories;
the build sorts the union by basename so the numbered series still applies in
order. The default build directory is `.bootloader/build-$UBOOT_PLATFORM`.

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
| read 2ndstage console log | `gkiw log` or host `gkiw-fastboot log` |
| decode Linux pstore | `fastboot oem pstore-display:console` |
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

U-Boot has its own pstore/ramoops decoder, so do not parse the raw region by
hand:

```sh
# decoded console records, over fastboot
fastboot oem pstore-display:console
fastboot oem pstore-display dmesg
fastboot oem pstore-display pmsg
global/harness/2ndstage/host/gkiw-fastboot pstore-display console
global/harness/2ndstage/host/gkiw-fastboot pstore-display dmesg

# or at the U-Boot prompt
pstore display console
pstore display dmesg
```

U-Boot's record names are `dump`, `console`, `ftrace` and `user`; the OEM
wrapper maps `dmesg`/`panic` to `dump` and `pmsg` to `user`. The Linux DT and
`CONFIG_CMD_PSTORE_*` sizes must match; the G12A build keeps them in sync, so use
the test image and 2ndstage from the same build.

While decoding, the wrapper silences the UART and pauses the persistent 2ndstage
log; only the fastboot stream receives the records. This avoids dumping the
whole log at 115200 baud and keeps the operation fast. `pstore display` prints
the records the same way `/sys/fs/pstore` exposes them on a running Linux
(`systemd-pstore` archives them there).

The G12A dev DT also reserves `0x1c100000..0x1c300000` for the 2ndstage log,
so a Linux boot cannot overwrite it, and constrains `linux,cma` to 128–384 MiB
so the CMA pool cannot overlap either region. `soc/amlogic/g12a/config.fragment`
turns on pstore/ramoops and keeps the Meson watchdog off until ssh works.

The G12A prototype memory map is part of the contract (the K-Touch i9 map is
in [its harness README](../../../device/ktouch/i9/harness/README.md)):

| Region | Address | Notes |
|--------|---------|-------|
| secure world / first stage | `0x00000000..0x08000000` | first 128 MiB, never used for data |
| fastboot buffer | `0x10000000..0x18000000` | 128 MiB |
| Linux pstore | `0x1c000000..0x1c100000` | 1 MiB |
| 2ndstage console log | `0x1c100000..0x1c300000` | 128 KiB, two slots |
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
the safe window, and reuse the generic patches unchanged. If U-Boot lacks a
target or driver for the SoC, add it as a SoC-scoped patch directory; the
MT6739 port is the example.

## Watchdog

`fastboot_preboot()` arms the first watchdog device before `bootm`, using
`CONFIG_GKIW_WDT_TIMEOUT_MS` (default 60 s). In the **working** state,
`CONFIG_WATCHDOG=y` makes U-Boot **service** it while it is running: the
fastboot loop calls `schedule()`, which runs the cyclic reset every second.
When U-Boot jumps to Linux the cyclic servicing stops, the hardware timer keeps
running, and Linux must take over within the configured timeout. If it does
not, the board resets.

The timeout is limited by the SoC, not by the harness. The Meson counter is
16-bit at 1 ms (about 65 s), so G12A uses 60 s. The MT6739 TOPRGU counter is
16-bit at 32768 Hz (about 16 s), so the K-Touch i9 fragment uses 15 s. Set it
per target in the U-Boot config fragment.

This is the intended behaviour for the development loop: U-Boot can wait in
fastboot indefinitely, a kernel that panics or wedges comes back on its own, and
a boot that must not be interrupted can use `gkiw watchdog off` from the UART
before booting.

### Bringup: do not service the watchdog in U-Boot yet

`CONFIG_WATCHDOG` makes U-Boot pet the watchdog from `schedule()`. During
bringup, leave it **unset**:

```text
# CONFIG_WATCHDOG is not set
CONFIG_WATCHDOG_AUTOSTART=y
CONFIG_WATCHDOG_TIMEOUT_MSECS=15000
```

U-Boot still starts the watchdog at init, but never services it. A hang before
or during USB/fastboot initialization therefore resets the board instead of
waiting for a human; that reset is the main debugging signal on a board with no
working console or fastboot. The trade-off is that U-Boot also resets while it
is sitting at the prompt, so use `gkiw watchdog off` on the UART, or set
`CONFIG_WATCHDOG_AUTOSTART=n` temporarily, when you need to type commands.

`CONFIG_WDT`, the SoC WDT driver and `CONFIG_CMD_WDT` stay enabled either way:
the watchdog must still be armed by `fastboot_preboot()` before `bootm` and be
controllable with `gkiw watchdog`.

Enable `CONFIG_WATCHDOG=y` only once `fastboot devices` (or
`gkiw-fastboot boot`) works reliably. At that point U-Boot may wait in fastboot
indefinitely, and the watchdog protects the Linux handoff instead of U-Boot
bringup.

### Blind bringup: watchdog beacons

If the board has no working console, `CONFIG_GKIW_BRINGUP_BEACONS` changes the
watchdog timeout at board milestones. The reset interval then identifies the
stage that hung: a short timeout means U-Boot got further than a long one. The
K-Touch i9 target uses 4 s after `board_late_init`, 8 s before MUSB init, 10 s
if the USB probe failed and 12 s if it succeeded; a hang before
`board_late_init` keeps the 15 s autostart timeout. This is a development aid,
not something to ship.

### Do not take over the watchdog yet

Until the **USB ACM shell** is reachable from the host (`socat - /dev/ttyACM0`
answers), the Linux kernel MUST NOT enable or pet the watchdog. The
second-stage reset is the only way out of a hung kernel; if Linux takes over
the timer, a wedged boot stops coming back and the loop needs a physical power
cycle. Keep the SoC watchdog driver off (and do not load it from the initramfs)
until the shell is reliable. Then enable it deliberately, either in-kernel or
with a userspace watchdog.

See [global/harness/linux](../linux/README.md) for the ACM shell setup.

## Second-stage console log

Every console character is written to a persistent 128 KiB region outside
U-Boot's BSS/stack/heap and the Linux pstore:

```text
0x1c100000..0x1c200000   slot 0: previous boot
0x1c200000..0x1c300000   slot 1: current boot
```

`CONFIG_GKIW_LOG_ADDR` / `CONFIG_GKIW_LOG_SIZE` select the region. On the first
console character of a boot, slot 1 (the last boot's log) is copied to slot 0
and a fresh ring starts in slot 1. A normal watchdog reset therefore preserves
the previous console; an ARM64 exception also appends `esr`, `elr`, `spsr` and
`x0..x30` to the current slot. Panic messages are in the console text; the
register dump is exception-only.

The header is `GLK2` with a ring head/used/size and a sequence number. It is
separate from ramoops, so the 2ndstage log never overwrites a Linux pstore.

On the next boot:

```sh
# over UART: previous slot by default
gkiw log
gkiw log current
gkiw log clear

# or from the host, parsing the two slots
global/harness/2ndstage/host/gkiw-fastboot log
# raw region if you want to inspect it yourself
global/harness/2ndstage/host/gkiw-fastboot pstore \
    --addr 0x1c100000 --size 0x20000 -o 2ndstage-log.bin
```

The host `log` command reads the previous slot by default; `--current` reads
the running boot.

## Build

```sh
global/harness/2ndstage/scripts/build.sh
# -> .bootloader/build-g12a/gkiw-2ndstage-flash.img  (v0, stock first stage)
#    .bootloader/build-g12a/u-boot.bin

# another target: the config selects its own defconfig, fragment, patches and
# GKIW_BOOTIMG_BASE, and names its build directory via UBOOT_PLATFORM
global/harness/2ndstage/scripts/build.sh \
    --soc device/ktouch/i9/harness/2ndstage.conf
# -> .bootloader/build-ktouch-i9/gkiw-2ndstage-flash.img
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

The image must satisfy the **stock first stage**, not a generic SoC datasheet.
Before inventing an address, decode the device's stock `boot.img` (or a
Lineage/TWRP `recovery.img` built for it) and copy the whole contract:

| Field | Where it comes from | Why it matters |
|-------|---------------------|----------------|
| header version | `mkbootimg` header | LK may only parse v0/v3 |
| page size | header | wrong pages shift every section |
| base | header | LK may ignore offsets and use a fixed address |
| kernel offset | header `kernel_addr - base` | the payload must land where LK jumps |
| ramdisk offset | header | empty is fine, but the field still exists |
| second offset/size | header | DTB may be in `second` or appended to the kernel |
| tags offset | header | ATAG/boot params destination |
| cmdline | header | MTK uses `bootopt=...` to select AArch64 |
| compression | kernel magic | stock MTK kernels are usually `Image.gz` |
| header flags | header | `booti` relocation/flags |

A chainload payload can be perfect and still never run because one of these
does not match. If the stock image is compressed, compress the 2ndstage kernel
too (`GKIW_BOOTIMG_COMPRESS=gzip`). If LK expects a fixed address, set
`GKIW_BOOTIMG_BASE` and `GKIW_BOOTIMG_KERNEL_OFFSET` so the header's
`kernel_addr` matches it, and link U-Boot at `kernel_addr + header_size`.

MTK example (K-Touch i9, taken from the LineageOS/TWRP `recovery.img`):

```text
base        0x40078000
kernel      0x40080000   (offset 0x00008000)
ramdisk     0x45000000   (offset 0x04f88000)
second      0x40f00000   (offset 0x00e88000, size 0)
tags        0x44000000   (offset 0x03f88000)
pagesize    2048
cmdline     bootopt=64S3,32N2,64N2 androidboot.selinux=permissive
kernel      Image.gz (gzip) with the *device* DTB appended after the gzip stream
second      empty; second_addr is still 0x40f00000
```

With the previous, guessed layout LK showed the bootlogo and then nothing; with
the stock layout it at least proceeded to the unlocked-bootloader warning. That
difference is the first-stage accepting the image, not U-Boot working yet.

#### G12A example

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
soc/amlogic/g12a/harness/2ndstage.conf     # base defconfig, fragment, defaults
soc/amlogic/g12a/harness/gkiw-g12a.config  # UART + fastboot + watchdog + gkiw
soc/amlogic/g12a/harness/patches/          # G12A DTS, memsize and board hooks
device/ktouch/i9/harness/2ndstage.conf     # MT6739 phone: addresses and patches
device/ktouch/i9/harness/patches/          # K-Touch i9 DTS and defconfig
soc/mediatek/mt6739/harness/patches/       # MT6739 mach/board/MUSB support
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
- **Watchdog size.** The timeout is capped by the SoC: about 65 s on Meson and
  about 16 s on MT6739. Set `CONFIG_GKIW_WDT_TIMEOUT_MS` below the hardware
  maximum or the driver clamps it silently.
- **Serviced watchdog hides bringup hangs.** With `CONFIG_WATCHDOG=y`, a hang
  in USB/fastboot init never resets because U-Boot pets the timer. Keep it off
  until fastboot enumeration works; see the bringup note above.
- **Android boot image only.** `fastboot boot` goes through U-Boot's Android
  image parser. Pack kernel/DT/initramfs with `mkbootimg`, not as raw files.
- **No vendor fastboot.** The 2ndstage cannot restore the stock U-Boot. A reset
  goes through the first stage and reloads the flashed `gkiw-2ndstage-flash.img`;
  use the vendor's own key combo/recovery path if you need its fastboot.
- **Arbitrary RAM read.** `oem pstore` reads any address the host asks for. It
  is a development tool: never ship it, never leave it reachable on a device you
  do not control.
