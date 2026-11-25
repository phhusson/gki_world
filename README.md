# gki_world

Out-of-tree, mainline-shaped drivers for smartphones, layered so that code is
shared at the right level and device-specific code stays device-specific.

The name is a joke at GKI's expense: GKI wanted a stable kernel with
out-of-tree drivers. gki_world is the version where the out-of-tree drivers are
the ones you would actually send upstream.

**Status: early scaffold.** The LTS and latest-release builds and the test
module work. The first device (Archos 50b Helium, MSM8916) is scaffolded but
does not boot yet. The development second stage builds for Amlogic G12A and
MediaTek MT6739; the K-Touch i9 port is scaffolded but not booted. The normative
design is [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the hands-on
workflow is [docs/bringup.md](docs/bringup.md).

## Layers

| Layer       | Path                          | Scope                            |
|-------------|-------------------------------|----------------------------------|
| global      | `global/`                     | helpers, global APIs, tooling    |
| SoC vendor  | `vendor/<vendor>/`            | code shared by one vendor's SoCs |
| SoC         | `soc/<vendor>/<soc>/`         | code for one SoC family          |
| device      | `device/<oem>/<codename>/`    | one phone model                  |

A build is exactly `global` + one `vendor` + one `soc` + one `device`. Code may
be copied between layers (forks are allowed) but never shadows the layer below.
All gki_world code is built as modules (`=m`).

SoC-scoped userspace (Mesa/OpenGL/Vulkan, video decoders) is not vendored. Each
SoC layer references a maintainer-owned git tree at an immutable commit, and
device layers cannot fork it.

## Kernel targets

The floor is the N-1 LTS (6.12 at the time of writing). The matrix is the two
current LTS releases, current stable, and torvalds master. Version differences
are handled with `#if LINUX_VERSION_CODE` in the driver, not with a shim layer.

New contributions must build against the newest LTS and the newest release
(`required: true` in `targets.yaml`). The older LTS and master are tracked but
do not block a merge.

## Machine-readable metadata

- [`docs/schemas/layer.schema.json`](docs/schemas/layer.schema.json) — every
  layer root has a `layer.yaml` (id, targets, maintainers, dependencies, device
  status).
- [`docs/schemas/provenance.schema.json`](docs/schemas/provenance.schema.json) —
  every driver directory has a `PROVENANCE` recording where the code came from
  (mainline, another gki_world layer, vendor source) and which blobs it needs.
- [`docs/schemas/userspace.schema.json`](docs/schemas/userspace.schema.json) —
  each SoC layer may reference maintainer-owned userspace trees (Mesa and
  friends) by immutable commit.

Examples live in [`docs/examples/`](docs/examples/).

## Building

```sh
make            # latest linux-6.18.y, arm64 defconfig, kernel + all modules
make modules    # rebuild gki_world modules only
make update     # move to the current 6.18.y tip and rebuild
```

The kernel checkout lives in `.kernel/` and is ignored. The cross compiler
defaults to `aarch64-linux-gnu-`; override `CROSS_COMPILE`, `ARCH`,
`KERNEL_REF` or `KERNEL_DIR` as needed. `global/test_module/` is a build smoke
test, not a driver.

The default ref is the newest LTS (`linux-6.18.y`). When a new LTS lands, bump
`KERNEL_REF` here and the LTS entry in `targets.yaml`, then fix the build behind
version guards. The checkout directory follows the ref, so the old tree stays
usable while the new one is brought up:

```sh
make KERNEL_REF=linux-6.20.y
```

The rest of the matrix is buildable the same way; each ref gets its own
`.kernel/<ref>` checkout:

```sh
make KERNEL_REF=linux-6.12.y   # N-1 LTS
make latest                    # newest non-rc release tag (currently v7.3.6)
make KERNEL_REF=v7.3.6         # a specific release
make master                    # torvalds master
make required                  # the merge gate: newest LTS + newest release
```

## License

Not decided yet; see the open items in the architecture document. Code is
expected to be GPL-2.0-only, compatible with the kernel.
