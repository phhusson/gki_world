# gki_world architecture

Status: design agreed, nothing implemented yet. This document is normative for
layout and policy. Sections marked *(planned)* describe tooling that does not
exist yet.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119.

## 1. Purpose

gki_world is an out-of-tree collection of mainline-shaped drivers for
smartphones. It exists so that agents and humans can port hardware support from
old vendor kernels to current Linux without waiting for upstream, while keeping
the result close enough to upstream that it can be submitted later.

The primary contribution path is an agent rewriting a vendor driver. The primary
maintenance path is an agent consolidating duplicated rewrites into shared
layers without breaking anyone.

### Non-goals

- Patching the Linux core.
- Android HALs, framework, or userspace stacks.
- Shipping proprietary firmware or blobs.
- Being a distribution or a ROM.

Small open-source userspace helpers are allowed when the hardware genuinely needs
them (for example a firmware loader). They live next to the driver that needs
them and follow the same provenance rules.

### Lifecycle

Upstream first. When upstream gains support for something gki_world carries,
gki_world MUST prefer upstream and shrink or delete the local copy. A device
entry that is fully upstreamed SHOULD become a thin config + DTS + harness
descriptor, or be removed.

## 2. Layers

| Layer      | Path                       | Scope                                                | Requires            |
|------------|----------------------------|------------------------------------------------------|---------------------|
| global     | `global/`                  | version-agnostic helpers, global APIs, shared tooling | —                   |
| SoC vendor | `vendor/<soc-vendor>/`     | code shared by all SoCs of one vendor                | `global`            |
| SoC        | `soc/<soc-vendor>/<soc>/`  | code for one SoC family                              | `vendor/<soc-vendor>` |
| device     | `device/<oem>/<codename>/` | one phone model                                      | `soc/<soc-vendor>/<soc>` |

The OEM is only a path component under `device/`; it is not a layer. "vendor"
without qualification always means the SoC vendor (qcom, mediatek, exynos,
tensor, ...).

A build is exactly one stack: `global` + one `vendor` + one `soc` + one
`device`. A device MAY skip the SoC layer only if it genuinely uses nothing from
it; this SHOULD be exceptional.

### 2.1 No shadowing

An upper layer MUST NOT shadow a file or symbol from a lower layer. The four
layer roots are all added to the include path, so a header basename MUST be
unique across the whole repository; the collision linter enforces this.

### 2.2 Forks are allowed

A device (or SoC) MAY copy any file from a lower layer or from mainline. This is
a deliberate trade: contribution speed beats elegance, and consolidation happens
asynchronously.

A fork MUST:

- rename file names, header names, the module name, exported symbols, and any
  non-static symbol that could collide;
- keep `static` helper names unchanged, so the copy can still be diffed against
  its origin;
- add a `PROVENANCE` entry of `kind: gkiw` pointing at the source layer and
  commit, plus the mainline/vendor sources of that code;
- not duplicate a DT compatible string inside the same device stack.

The rename is mechanical and the collision linter can suggest it. A fork PR
SHOULD NOT be rejected for naming when the bot can fix it.

Module names MUST identify their owner structurally, e.g. `sdm845_rn5t619` for
an SoC-layer driver, `beryllium_rn5t619` for a device fork, `gkiw_foo` for a
global module. Duplicate module names are a hard load failure on device.

## 3. Kernel targets

- Floor: the N-1 LTS, currently 6.12. The floor moves when an LTS reaches EOL;
  it is not extended backwards.
- Matrix: the two current LTS releases (6.12 and its successor), current stable,
  and torvalds master. The concrete list lives in
  [`targets.yaml`](../targets.yaml).
- Required builds: every new contribution MUST build against the newest LTS and
  the newest release (`required: true` in `targets.yaml`). The N-1 LTS and
  master are tracked and built by CI, but they do not block a merge.
- A layer MAY narrow `targets:` in its `layer.yaml` (for example a driver only
  needed on 6.18+). It MUST NOT widen beyond the global set.
- No compatibility shims. Version differences are handled with
  `#if LINUX_VERSION_CODE` inside the driver. Guards SHOULD be few, grouped at
  the top of the affected function, and MUST be deleted when the oldest target
  is dropped.
- Preprocessor conditionals are for API shape only. Vendor or device policy
  MUST NOT be selected by `#ifdef`.
- Code SHOULD look like it could be sent to LKML modulo the renames: SPDX
  headers, kernel coding style, no vendor-private uapi, no dead debug code.

## 4. Modules only

All gki_world code is built as modules (`=m`). This is the GKI model: the kernel
image is not ours, the drivers are.

Consequences:

- **Config is split in two.** The kernel `.config` contains in-tree features
  needed to boot (pstore/ramoops, the USB device controller, storage, etc.) and
  may use `=y`. gki_world module selection is separate and always `=m`. A
  `CONFIG_...=y` for a gki_world driver is a review failure.
- **Early boot is a module-ordering problem.** Anything needed for storage,
  display or the harness MUST be loadable from the initramfs. Each device build
  produces a `modules.load` in dependency order (host-side `depmod -n`), and the
  harness initramfs loads it explicitly. There is no udev.
- **No core patches.** If a driver needs an unexported symbol or a core
  behaviour change, the options are, in order: use an exported API; copy the
  helper into the module under the copy rules; mark the device `wip` with a
  documented blocker and submit the core change upstream. `patches/<target>/` is
  not infrastructure we want; if it ever becomes necessary it needs its own
  maintainer set and mandatory upstream links.

The harness builds the kernel and the modules together, so vermagic and module
signing are consistent by construction. Loading gki_world modules into an
unmodified stock kernel is not a supported mode.

## 5. Repository layout

```text
gki_world/
  README.md
  docs/
    ARCHITECTURE.md
    schemas/
    examples/
  global/
    layer.yaml
    include/
    uapi/
    api/                  # documentation for global APIs
    tools/                # bootimg, initramfs, firmware fetch, evidence
  vendor/
    qcom/layer.yaml
    mediatek/layer.yaml
  soc/
    qcom/sdm845/
      layer.yaml
      userspace.yaml      # optional maintainer-owned userspace refs
  device/
    xiaomi/beryllium/
      layer.yaml
      board.dts
      config.fragment
      config              # optional tested snapshot
      bootimg.yaml
      firmware.yaml
      harness/
      drivers/            # optional forks
      PROVENANCE
```

Directory names are lowercase, no spaces. A layer directory MUST contain
`layer.yaml`. Driver directories MUST contain `PROVENANCE`.

## 6. layer.yaml

Every layer root, including every device, has a `layer.yaml` validated against
[`schemas/layer.schema.json`](schemas/layer.schema.json).

| Field         | Required | Meaning |
|---------------|----------|---------|
| `schema`      | yes      | schema version, currently `1` |
| `kind`        | yes      | `global`, `soc-vendor`, `soc`, `device` |
| `id`          | yes      | canonical id matching the path (`global`, `vendor/qcom`, `soc/qcom/sdm845`, `device/xiaomi/beryllium`) |
| `description` | no       | one line |
| `requires`    | no       | layers this one builds on |
| `targets`     | no       | narrows the global target set |
| `maintainers` | yes      | GitHub handles; for a new device, the poster |
| `status`      | devices  | `boots`, `builds`, `wip` |
| `boots_sha`   | if boots | commit at which boot evidence was last produced |

Rules:

- `requires` MUST respect the layer order in section 2.
- `targets`, when present, MUST be a subset of the global targets.
- On `main`, a device MUST be `status: boots` with a matching `boots_sha`.
  `builds` and `wip` are valid on branches and in open PRs.
- `boots_sha` is evidence age, not a promise. Shared-layer changes do not update
  it; a dashboard reports stale evidence.

## 7. Provenance and licensing

Every driver directory has a `PROVENANCE` file validated against
[`schemas/provenance.schema.json`](schemas/provenance.schema.json). One file per
driver directory is enough; it describes all files in that directory.

```yaml
schema: 1
license: GPL-2.0-only
sources:
  - kind: mainline          # mainline | gkiw | vendor | other
    path: drivers/mfd/rn5t618.c
    commit: 6f5e2a1
    license: GPL-2.0-only
    derived: [rn5t618-core.c, rn5t618-regmap.c]
  - kind: gkiw
    path: soc/qcom/rn5t619
    commit: <gkiw sha>
    derived: [rn5t619-regulator.c]
  - kind: vendor
    url: https://github.com/xiaomi-sm8250/kernel
    commit: <sha>
    path: drivers/mfd/rc5t619.c
    license: GPL-2.0-only
    derived: [rc5t619-regulator.c]
blobs:
  - purpose: touch firmware
    device_path: /vendor/firmware/touch.bin
    dump: dumps.tadiphone.dev/<dump>/vendor.img
    sha256: <64 hex>
notes: generalized rn5t618 to also cover rc5t619
```

- `sources` is a list. A driver assembled from several upstreams, vendor trees
  or gki_world layers MUST list each one.
- `derived` says which local files came from that source. Paths are relative to
  the `PROVENANCE` directory. The drift job uses this to diff against pinned
  sources.
- `kind: gkiw` plus a commit gives the fork graph the consolidation bot needs.
- `blobs` are never committed. Each entry needs a fetch recipe (`dump` or `url`)
  and a `sha256`. Firmware is fetched at build or first-boot time.
- Every source file carries its own SPDX identifier. GPL vendor code stays
  GPL-2.0-only; the top-level `license` MUST be compatible with every source.
- The linter rejects missing sources, license mismatches, blobs without hashes,
  and `derived` paths that do not exist.

## 8. SoC userspace references

GPU userspace (Mesa/OpenGL/Vulkan) and similar SoC-scoped userspace are
properties of the SoC, not of a phone. gki_world does not vendor them. It
references maintainer-owned git repositories at immutable commits, in
`soc/<vendor>/<soc>/userspace.yaml`, validated against
[`schemas/userspace.schema.json`](schemas/userspace.schema.json).

```yaml
schema: 1
components:
  - name: mesa
    role: graphics                 # graphics | video | firmware-loader | other
    apis: [opengl, vulkan]
    drivers: [freedreno, turnip]
    kernel_driver: msm             # mainline DRM driver it pairs with
    upstream: https://gitlab.freedesktop.org/mesa/mesa
    upstream_ref: <sha>            # must be an ancestor of ref
    repo: https://github.com/<soc-maintainer>/mesa
    ref: <sha>                     # immutable commit, never a branch or tag
    patches:
      - https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/...
    build: -Dgallium-drivers=freedreno -Dvulkan-drivers=freedreno  # hint only
```

Rules:

- `ref` MUST be a full commit sha, never a branch or tag, and the repository
  MUST be publicly and anonymously fetchable. `upstream_ref` MUST be an ancestor
  of `ref`, so `git log upstream_ref..ref` is the exact patch list. Published
  refs are append-only; rebasing one is a breaking change. CI checks
  reachability and ancestry. `upstream`/`upstream_ref` are required for
  `role: graphics` and optional for cleanroom components.
- The reference belongs to the SoC layer maintainers. gki_world MUST NOT mirror,
  vendor or submodule these trees; tooling clones into a build cache.
- Device layers MUST NOT contain `userspace.yaml` and MUST NOT fork these
  components. A device-specific fix goes into the SoC reference. This
  deliberately makes graphics a SoC-maintainer responsibility and prevents
  per-phone Mesa forks.
- `kernel_driver` names the mainline DRM driver the component pairs with. A SoC
  whose only GPU stack is a vendor blob (kbase and friends) has no supported
  graphics userspace; blob wrappers and HALs are out of scope.
- GPU firmware stays fetch-only under the kernel driver's `PROVENANCE` `blobs`.
- gki_world describes the pairing; it does not package Mesa. The Vulkan loader,
  libdrm and distribution packaging are downstream. `build` is a hint, not a
  recipe.
- Keeping Mesa (MIT) as a reference also keeps the GPL-2.0-only boundary clean.
- The same mechanism covers other SoC-scoped userspace through `role` (video
  decoders, firmware loaders).

## 9. Device anatomy

```text
device/xiaomi/beryllium/
  layer.yaml          # id, requires, targets, maintainers, status, boots_sha
  board.dts           # includes the SoC dtsi (local fork if modified)
  config.fragment     # merged with vendor/, soc/ and global/ fragments
  config              # optional full .config of a tested build
  bootimg.yaml        # data for the shared boot image tool
  firmware.yaml       # fetch-only blob descriptions
  harness/            # device-specific scripts, if any
  drivers/            # forked drivers, each with PROVENANCE
  PROVENANCE          # when drivers/ exists
```

A device MUST NOT contain `userspace.yaml` or fork SoC userspace components;
those are referenced from the SoC layer (section 8).

### Configuration

`config.fragment` is required and merged with `scripts/kconfig/merge_config.sh`
in layer order. A full `config` MAY be committed only as a snapshot of a known
good build; it is not the source of truth.

### Device tree

Mainline style: `board.dts` includes the SoC `.dtsi`. If the device needs a
change to the SoC tree, it forks the dtsi locally and includes the fork. There is
no DT overlay magic by default; a device that needs DTBOs documents it in
`bootimg.yaml`.

### Boot images

One shared tool, per-device data. `bootimg.yaml` describes header version,
page size, cmdline, compression, vendor_boot split, AVB handling, and the stock
image used as a template. Device-specific packing scripts MUST NOT exist unless
the format genuinely cannot be expressed as data.

## 10. Harness and bringup

The practical guide is [bringup.md](bringup.md). This section is the shape of the
harness; that document is the workflow and the footguns.

### Flow

1. Fetch the stock boot image from `dumps.tadiphone.dev` (cached by hash) or use
   a local file.
2. Build the kernel for the device config and the gki_world modules for each
   target being tested.
3. Generate `modules.load` from `depmod -n`.
4. Build the initramfs.
5. Pack the boot image with the shared tool.
6. Flash and boot; collect evidence over USB.
7. On the next boot, collect the previous boot's pstore.

### initramfs

- Default image: a small static C `init`. It mounts `/proc`, `/sys`,
  `/dev`, and configfs; loads `modules.load` in order; configures the USB gadget
  (`libcomposite` → `usb_f_acm` → `g_serial`); dumps the previous boot's pstore
  and the current `/dev/kmsg` to `ttyGS0`; writes a `gkiw-evidence` bundle; then
  sleeps or execs `/init.real`.
- `DEBUG=1`: the same image plus a static busybox and `exec /bin/sh`. Bringup
  without a shell is miserable; the 1 MB is worth it. This image is never used
  as evidence.
- The initramfs embeds `gkiw-release` (commit sha, target, device, config hash)
  so evidence can be bound to the build that produced it.

### pstore / ramoops

The device tree reserves a `ramoops` region and the kernel enables
`PSTORE_RAM`, `PSTORE_CONSOLE`, `PSTORE_PMSG` and `PSTORE_FTRACE` as needed.
These are in-tree core options, so `=y` is fine. The harness init dumps
`/sys/fs/pstore/*` from the previous boot before anything else can overwrite it,
then clears the records.

### Watchdog

A wedged boot must reboot instead of hanging a human or a CI runner. Devices
SHOULD use the hardware watchdog (`nowayout=0` plus a daemon or a kernel
`panic_timeout`), and the harness SHOULD set a bounded boot timeout.

### Evidence

A device change requires an evidence bundle from the device:

```text
gkiw-evidence/
  release        # gkiw-release, commit sha
  version        # uname -a, /proc/version
  compatible     # /proc/device-tree/compatible
  modules        # lsmod
  dmesg
  pstore/        # previous boot, if any
```

The `release` file MUST match the PR head commit. `boots` status and auto-merge
require this bundle; shared-layer changes do not, because their maintainers
cannot boot every phone.

### Console

`earlycon` and `keep_bootcon` on the kernel cmdline, `CONFIG_MAGIC_SYSRQ` for
recovery, and `g_serial` on `ttyGS0` (host sees `/dev/ttyACM0`). Network gadget
is an optional extra when logs outgrow a tty.

## 11. CI

Two builds, with different jobs:

1. **Per-device build.** The device's stack, all gki_world modules `=m`. At
   minimum every `required: true` target (newest LTS and newest release) is
   built for a PR; the remaining declared targets run nightly and are advisory
   for merge. This is the shipping shape and the only build that proves a
   device.
2. **Universe compile.** Every layer, every target, every module `=m`, no device
   selected. This exists only to catch shared-tree breakage and header drift. It
   never ships, and booting it is explicitly not required.

The universe build runs when shared paths change (`global/`, `vendor/`, `soc/`)
and nightly. A device-only PR runs its own build plus the linter.

### Collision linter

Compiling everything does not catch collisions; the linter does. It compares the
build output against the nightly `symbols/index` artifact:

- module names (hard failure: duplicate `.ko` names cannot both be installed);
- exported symbols (hard failure: first-wins resolution is a footgun);
- DT compatible strings (warning, or failure if duplicated within one stack);
- Kconfig symbols and header basenames (failure on duplicate definition).

The linter is blocking for auto-merge. It can suggest the mechanical rename for
forked files.

### Other jobs

- `provenance`: schema validation, license compatibility, no blobs in git.
- `evidence`: bundle format and `release` sha, for device changes.
- `ai-review`: see section 12.
- `build-map`: maps changed paths to affected device stacks via `requires` and
  provenance, so CI does not rebuild phones that cannot be affected.

## 12. Contribution and merge

### Maintainer sets

Each `layer.yaml` lists maintainers. A contributor who adds a new device becomes
the maintainer of that device directory only; they gain no rights over `soc/`,
`vendor/` or `global/`.

### Auto-merge

A PR merges without human review when all of these hold:

- the author is a maintainer of every layer the PR touches, or the PR creates a
  new device directory;
- per-device builds for the required targets (newest LTS and newest release),
  the linter, provenance and evidence checks pass;
- AI review passes;
- for a device change, `status: boots` with evidence at the PR head.

Anything touching a layer above the author's ownership needs that layer's
maintainer. Shared-layer changes require build + linter only, not boot evidence.

### AI review

The review is part of the gate, so it must be reproducible: pinned model,
versioned prompt, transcript attached to the PR, re-runnable on demand. It blocks
on layering violations, missing or wrong provenance, non-mainline APIs without a
global definition, vendor uapi, blobs in git, `=y` drivers, and the footguns in
section 15. It is advisory on style and consolidation. A human maintainer MAY
override a false negative with a note.

## 13. Consolidation

- Direction is up only: device → SoC → vendor → global. Never down.
- Trigger: two or more users of equivalent code, detected from the provenance
  fork graph plus normalized similarity (comments and whitespace ignored).
- The bot opens the PR, targets the lowest common layer, and must build every
  affected stack. Boot evidence is not required.
- Target-layer maintainers (or their agents, under the same auto-merge rules)
  approve. Existing forks need not migrate: they either delete the local copy or
  record a new fork point.
- Consolidation PRs are batched and low priority. They never block a feature
  PR, and a device maintainer may keep a fork indefinitely.

## 14. API policy

- If mainline has an API, use it. No vendor-private interfaces.
- If mainline lacks an API, define it once globally:
  - kernel-internal: `global/include/` with a `gkiw` prefix;
  - userspace: `global/uapi/`, shaped as if it were going upstream;
  - documentation: `global/api/<name>.md` with semantics, why it is not
    upstream, and a link to any upstream discussion.
- A device MUST NOT define private uapi. Adding one is a blocking review failure.
- When upstream grows an equivalent API, the global one is deprecated with a
  migration note and removed once users have moved.

## 15. Known footguns

To expand into `docs/bringup.md`:

- kCFI: out-of-tree modules must be built with the same toolchain and CFI
  settings as the kernel. `__nocfi` is a red flag.
- `CONFIG_TRIM_UNUSED_KSYMS` and missing `Module.symvers`: modpost failures that
  look like missing APIs.
- `CONFIG_MODVERSIONS` CRC mismatch: module loads, then symbol versioning
  disagrees.
- Module signing and `MODULE_SIG_FORCE`: build and boot must agree.
- `fw_devlink` and probe deferral loops: the usual culprit behind "device
  present, driver never probes".
- Regulator, clock and genpd ordering: `-EPROBE_DEFER` is normal, an infinite
  loop is not.
- Mainline replacements: memfd over ashmem, dma-heap over ION, binderfs over the
  old binder device node.
- sysfs and uevent ABI: `MODULE_DEVICE_TABLE` plus `modules.alias` is how
  autoload works when there is no udev.
- Suspend/resume and runtime PM: the most common post-boot regression.
- DT: a modified SoC dtsi must be forked locally, not patched in place.

## 16. Open items

- Repository license (code GPL-2.0-only; docs license to choose).
- Rotation policy when a new LTS lands: bump `targets.yaml`, drop the old
  target's guards, update the floor.
- Boot image tool scope: which formats and AVB cases are data vs. code.
- Evidence trust model: signing or CI attestation beyond the release sha.
- Whether full `.config` snapshots belong in git.
- CI provider and where the nightly symbol index is stored.
- Fetch tooling for SoC userspace references, and whether the harness gets a
  graphics smoke test.
