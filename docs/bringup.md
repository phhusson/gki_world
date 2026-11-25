# Bringing up a phone

Status: design guide. Tooling named here is the intended interface; see
[ARCHITECTURE.md](ARCHITECTURE.md) for the normative rules. When this document
and the architecture disagree, the architecture wins.

The goal of a bringup is not "all hardware works". It is: the kernel built from
gki_world boots on the phone, produces evidence, and the device entry can be
merged. Drivers are added incrementally afterwards.

## 0. Definition of done

A device entry is mergeable when:

- `device/<oem>/<codename>/` validates (`layer.yaml`, config fragment, DTS,
  `bootimg.yaml`, `PROVENANCE` for any forks);
- the per-device build passes for the required targets (newest LTS and newest
  release) and SHOULD pass for the rest;
- the collision linter passes against the nightly index;
- `status: boots` and `boots_sha` match the PR head;
- the evidence bundle below was produced from that exact build.

The PR then auto-merges if the author is the new device's maintainer.

```text
gkiw-evidence/
  release        # commit sha, target, device, config hash
  version        # uname -a, /proc/version
  compatible     # /proc/device-tree/compatible
  modules        # lsmod
  dmesg
  pstore/        # previous boot, if any
```

## 1. Gather the device data

Before writing anything, collect:

- codename: `adb shell getprop ro.product.device`, `ro.product.name`,
  `ro.build.fingerprint`;
- SoC: `ro.board.platform`, `ro.soc.model`, or the first compatible in
  `/proc/device-tree/compatible`;
- RAM size and partition layout: `ls -l /dev/block/by-name`;
- A/B: `ro.boot.slot_suffix`, presence of `boot_a`/`boot_b`;
- boot format: header version from the stock image, and whether the ramdisk
  lives in `boot` or `vendor_boot`;
- stock images from `dumps.tadiphone.dev` (boot, vendor_boot, dtbo, super) or a
  local dump. Record the dump name in `bootimg.yaml`/`firmware.yaml`.

Put the identifiers in `layer.yaml`:

```yaml
schema: 1
kind: device
id: device/xiaomi/beryllium
description: Xiaomi Pocophone F1 (sdm845)
requires: [soc/qcom/sdm845]
maintainers: ["@you"]
status: wip
```

## 2. Device tree

Write mainline style, even when starting from the vendor DTB:

- `board.dts` includes the SoC dtsi: `#include "sdm845.dtsi"` (or the local fork).
- Extract the vendor tree for reference with
  `dtc -I dtb -O dts -o vendor.dts stock.dtb`; do not copy its structure
  wholesale.
- If the SoC dtsi needs a change, fork it into the device (or SoC) layer under a
  new name, add a `PROVENANCE` entry, and include the fork. Never patch a shared
  dtsi in place.
- Start with the minimum needed to boot and get a console: CPUs, memory, the
  reserved-memory regions (ramoops, firmware, remoteproc if needed), the USB
  device controller, and the storage path if you intend to mount anything.

Reserved memory for pstore:

```dts
reserved-memory {
    ramoops@a0000000 {
        compatible = "ramoops";
        reg = <0 0xa0000000 0 0x400000>;
        record-size = <0x40000>;
        console-size = <0x100000>;
        pmsg-size = <0x80000>;
        ftrace-size = <0x80000>;
        no-map;
    };
};
```

## 3. Configuration

Two kinds of options, and they do not mix:

- **Core kernel** (in-tree): boot-critical features and the harness transport.
  These may be `=y`. Examples: `PSTORE`, `PSTORE_RAM`, `PSTORE_CONSOLE`,
  `PSTORE_PMSG`, `PSTORE_FTRACE`, `MAGIC_SYSRQ`, `DEBUG_FS`,
  `USB_GADGET`, `USB_CONFIGFS`, `USB_CONFIGFS_ACM`, and the UDC driver for the
  SoC.
- **gki_world drivers**: always `=m`. A `CONFIG_...=y` for a driver in this
  repository is a review failure.

Start `config.fragment` small; the merged config comes from
`global` + `vendor` + `soc` + `device` fragments. Useful harness options beyond
the list above: `DYNAMIC_DEBUG`, `IKCONFIG_PROC`, `PANIC_ON_OOPS`,
`PANIC_TIMEOUT`, and a hardware watchdog. Do not enable `MODULE_SIG_FORCE` for
bringup unless the bootloader demands it.

The build produces `modules.load` in dependency order; the initramfs loads it.
If storage or display is needed for the harness, it must be in that list.

## 4. Drivers

1. Inventory hardware from the vendor DTS and `/sys`: regulators, clocks, pinctrl,
   USB PHY/controller, storage, display, touch, PMIC, thermal.
2. Find the mainline driver first. If none exists, find the vendor source on
   GitHub (record the URL and commit) or copy a close mainline driver.
3. Generalize rather than special-case: a copied `rn5t618` that also covers
   `rc5t619` is the intended pattern. Rename files, the module, exported and
   non-static symbols; keep `static` helper names.
4. Add `PROVENANCE` with every source, a `kind: gkiw` entry if you forked a
   layer, and fetch-only blob entries. A driver directory without it does not
   pass CI.
5. A driver that probes and logs but does not fully work is progress. Register
   it, get `dmesg` clean enough, and move on; bringup is incremental.

Module naming: `<soc>_<driver>` or `<codename>_<driver>` / `gkiw_<driver>`.

Do not add private uapi. If a userspace interface is genuinely missing from
mainline, define it once under `global/` per the API policy, with documentation
and an upstream plan.

## 5. Harness and images

`bootimg.yaml` describes, for this device:

- boot format and header version;
- page size, cmdline, compression;
- whether the ramdisk goes in `boot` or `vendor_boot` (GKI devices usually put
  it in `vendor_boot`, with the DTB in `dtb`/`dtbo`);
- AVB: whether verification must be disabled, and how;
- the stock image used as a packing template, by dump name and hash;
- anything the shared tool cannot infer (extra sections, offsets, signing).

The shared tool does the packing. A device-specific script is a last resort and
must be justified in review.

Flashing reminders:

- unlocked bootloader is assumed; AVB still needs `vbmeta` handling on some
  devices;
- on A/B devices flash the active slot, or set it explicitly;
- a wrong `vendor_boot`/`dtbo` combination usually manifests as "no output at
  all", not as a driver failure.

### initramfs

Default image: static C `init` that:

1. mounts `proc`, `sysfs`, `devtmpfs`, configfs;
2. loads `modules.load` in order;
3. configures the USB gadget (`libcomposite` + `usb_f_acm`) and exposes
   `ttyGS0`;
4. reads `/sys/fs/pstore/*` (previous boot), then clears it;
5. writes `gkiw-evidence/` and copies it to `ttyGS0`;
6. sleeps, or execs `/init.real` if present.

`gkiw-release` (commit, target, device, config hash) is baked into the image.
Evidence without it is not evidence.

`DEBUG=1` adds a static busybox and drops to `/bin/sh`. Use it while the gadget
or module order is still fighting you; never use it for evidence.

## 6. Boot debugging

Add to the cmdline while bringing up:

```text
earlycon keep_bootcon ignore_loglevel loglevel=8 initcall_debug
```

Order of investigation:

- **No output at all**: boot header, compression, DTB placement, wrong
  partition, AVB. Check with the stock image first; then change one variable.
- **Output stops early**: missing console/earlycon, missing clock or regulator
  for the UART, wrong `stdout-path`.
- **Reboot loop**: watchdog (good, it is doing its job) or panic. Read the
  previous boot from pstore; the reason is usually in the last 100 lines.
- **Hangs later**: deferred probe loop, missing firmware, regulator/clock
  ordering. `initcall_debug` and dynamic debug on the suspect driver.
- **Boots but no gadget**: UDC driver not loaded, configfs not mounted, wrong
  UDC name in `/sys/class/udc`.

Recovery path: `CONFIG_MAGIC_SYSRQ`, serial/earlycon where available, and a
hardware watchdog with `nowayout=0` so a wedged boot resets instead of waiting
for a human. During early bringup, do **not** let Linux take over the watchdog
until a remote shell works: the bootloader-armed reset is the way out of a hung
kernel. Enable the kernel watchdog deliberately once ssh is reliable.

## 7. Evidence and PR

Capture from the host:

```sh
socat - /dev/ttyACM0,raw,echo=0 > gkiw-evidence.tar
```

or mount the device and copy `gkiw-evidence/`. Verify that `release` matches the
PR head, set `status: boots` and `boots_sha`, and include the bundle in the PR.
The evidence check is blocking; the AI review and the linter run on the same
commit.

If the device cannot boot yet, keep the PR open with `status: wip`. It does not
merge, and it does not bother anyone.

## 8. Footguns

### Build and load

- **kCFI**: modules must be built with the same toolchain and CFI/LTO settings
  as the kernel. `__nocfi` is a red flag, not a fix.
- **`TRIM_UNUSED_KSYMS`**: with an external `Module.symvers`, missing symbols
  look like missing APIs. Build kernel and modules together.
- **`MODVERSIONS`**: CRC mismatch loads then fails symbol resolution; keep the
  build tree and module tree from the same build.
- **Module signing**: `MODULE_SIG_FORCE` makes unsigned modules silently
  unloadable; decide before the first flash.
- **Compressed modules**: the initramfs loader must be able to decompress them.
  Keep the harness uncompressed.
- **`EXPORT_SYMBOL_GPL` and namespaces**: only exported symbols are reachable;
  copy a helper rather than patching core.

### Probing

- **`fw_devlink` / deferred probe**: the usual cause of "device present, driver
  never probes". Check `deferred_probe` in debugfs.
- **Regulator, clock, pinctrl, genpd, interconnect**: `-EPROBE_DEFER` is normal;
  a loop is not. Find the dependency that never appears.
- **DT matching**: `compatible` must match `of_device_id`; no udev means
  autoload relies on `MODULE_DEVICE_TABLE` + `modules.alias`.
- **Reserved memory**: `no-map` regions must not overlap; remoteproc and
  ramoops are common collisions.

### Runtime

- Suspend/resume and runtime PM are the most common post-boot regressions.
- sysfs/uapi ABI changes break userspace silently; keep mainline shapes.
- Watchdog: `nowayout=0` during bringup, and know who pets it.

### Android legacy

Mainline replacements, not compatibility layers:

| Legacy        | Mainline                          |
|---------------|-----------------------------------|
| ashmem        | memfd (`sys.use_memfd=1`)         |
| ION           | dma-heap                          |
| binder node   | binderfs                          |
| lowmemorykiller | PSI + lmkd                      |
| fbdev         | DRM                               |
| early suspend | runtime PM                        |
| `wake_lock`   | wakeup sources                    |

### Images

- `boot` vs `vendor_boot` vs `dtbo`: on GKI-era devices the ramdisk and DTB are
  usually not in `boot`. Get this wrong and the phone appears dead.
- AVB: unlocked is not always enough; some devices need `vbmeta` flags cleared.
- Do not flash a mismatched stock/vendor pair and then debug the kernel.

## 9. Checklist

- [ ] identifiers and SoC recorded in `layer.yaml`
- [ ] `board.dts` builds, includes the right SoC dtsi
- [ ] config fragment is core-options-only + `=m` drivers
- [ ] pstore/ramoops reserved and enabled
- [ ] watchdog enabled, `nowayout=0`
- [ ] USB gadget + `ttyGS0` works
- [ ] `modules.load` generated and loaded
- [ ] at least one driver per boot-critical block has `PROVENANCE`
- [ ] evidence bundle captured, `boots_sha` set
- [ ] linter, build and evidence green
