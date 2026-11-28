# Archos 50f Helium Linux bringup

Base: `msm8916-mainline/linux`, branch `wip/msm8916/6.18-rc6`. The board tree
`board.dts` is minimal: CPU/memory from the SoC dtsi, peripheral-mode USB
(ci_hdrc + ULPI PHY), PM8909 PWM, ramoops and a reserved marker page. Storage,
display and the modem are not enabled yet.

## RPM / regulators

The APCS mailbox works and the RPM regulator, clock and power-domain drivers
probe, so the USB PHY uses the real PM8909 rails (`v1p8 = L7`,
`v3p3 = L13`) from `qcom-msm8909-pm8909.dtsi`.

Two things are needed for that on MSM8909:

* `board.dts` drops the `clocks`/`clock-names` properties from the APCS node.
  They belong to the APCS CPU clock driver, which we do not use, and fw_devlink
  otherwise blocks the mailbox until the `a7pll` supplier probes.
* `CONFIG_QCOM_A53PLL` must stay **off**. The PLL block at `0xb016000` does not
  respond on this SoC and hangs the boot before console init, even without
  `CONFIG_QCOM_CLK_APCS_MSM8916`. Without it the CPU stays at the
  bootloader-programmed rate.

`CONFIG_POWER_RESET_QCOM_PON` is required: it binds the PON node, which then
populates its children. Without it the `qcom,pm8916-wdt` device is never
created, so nothing pets the PMIC watchdog armed by the second stage and the
phone resets about 60 s after every boot.

## Storage and input

* **eMMC**: `&sdhc_1` (8-bit, HS200) on the PM8909 L5/L8 rails. The stock
  Android GPT is readable as `mmcblk0` with 29 partitions.
* **Keys**: PMIC `pwrkey` (power) and `resin` (volume down, `KEY_VOLUMEDOWN`),
  plus TLMM GPIO 90 as `gpio-keys` volume up (active low).
* **Touchscreen**: FocalTech FT6436 at I2C address `0x38` on **BLSP1 QUP5**
  (`0x78b9000`, GPIO 18/19), reset GPIO 12, IRQ GPIO 13, L17/L6 rails. The
  stock QRD DTS puts a second touch node on QUP3; this board is on QUP5.
  The mainline `edt-ft5x06` driver needs the `focaltech,ft6436` compatible and
  probes it as `EP0110M09`.
* **Accelerometer**: Bosch BMA222E (chip ID `0xf8`) at `0x18` on **BLSP1
  QUP1** (`0x78b5000`, GPIO 6/7), interrupt GPIO 96, L17/L6 rails. The
  `bma180` driver gets a BMA222E entry using the BMA250 register set.

## Known gaps

* **Display**: a real MDP3 DRM/KMS driver (`patches/0004-mdp3-drm.patch`)
  takes over the primary DMA that the bootloader left running.  It exposes a
  fixed 720x1280 RGB888 CRTC/plane and a DPI connector, allocates dumb buffers
  from CMA and page-flips by writing the buffer address to the MDP3 primary
  DMA (register `0x90008`).  The MDSS clocks/GDSC are held on and the PM8909
  LPG PWM backlight is enabled, so the fbcon and `/dev/fb0` draw on the panel
  and the initramfs colour bars are visible.  The DSI controller, PHY and panel
  initialisation are still done by LK; user-triggered modesetting is future
  work.
* **Audio/microphone**: the stock card is `msm8909-skue-snd-card` with the
  internal "tombak" codec and the PM8909 WCD analog block at SPMI `0xf000`
  (`qcom,msm8x16_wcd_codec`). The MSM8909 LPASS/tombak digital side is not
  described by mainline; this needs LPASS nodes, DSP firmware (the stock
  `modem`/NON-HLOS image), a machine driver and UCM. The stock mixer paths are
  in `/etc/mixer_paths_skue_t302.xml` inside the dump's `system.img`.
* **ALS**: the Epticore EM3071x at `0x24` on QUP1 is enabled by a minimal
  local IIO driver (`patches/0003-em3071x-als.patch`) derived from the vendor
  driver. It reports a 12-bit ALS count and a nominal `raw * 10` lux; proximity
  is not implemented. The part only answers SMBus *word* reads.

## USB console

The USB PHY is driven by `ci_hdrc` in peripheral mode and the shared initramfs
builds a two-port USB ACM gadget (`1b8e:fada`): `/dev/ttyACM0` on the host is
the root shell, `/dev/ttyACM1` is the watchdog heartbeat. There is no UART
console: the second stage hangs when it touches the debug UART.

## Build (ARMv7)

```sh
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- qcom_defconfig
./scripts/kconfig/merge_config.sh -m .config \
    device/archos/ac50fhe/linux/config.fragment
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j16 zImage dtbs

BUSYBOX=/path/to/armhf-static-busybox CC=arm-linux-gnueabihf-gcc \
    global/harness/linux/build-initramfs.sh /tmp/gkiw-acm-initramfs.cpio.gz
```

Wrap `zImage`, the DTB and the initramfs with `mklinuximg.sh`. It sets the load
addresses the second stage expects; with the `mkbootimg` defaults the DTB lands
at `0x01000100`, inside the kernel, and Linux dies before console init.

```sh
device/archos/ac50fhe/linux/mklinuximg.sh \
    zImage \
    arch/arm/boot/dts/qcom/qcom-msm8909-archos-ac50fhe.dtb \
    /tmp/gkiw-acm-initramfs.cpio.gz \
    /tmp/linux-boot.img
```

Then, from U-Boot fastboot (not stock LK; LK has no `oem pstore`):

```sh
fastboot boot /tmp/linux-boot.img
global/harness/2ndstage/host/gkiw-heartbeat /dev/ttyACM1 &
```

The initramfs exposes a root shell on `/dev/ttyACM0`. Keep the heartbeat
running or the phone resets (see below).

## Watchdog

The second stage arms the PMIC PON watchdog for 60 s just before booting Linux.
`pm8916_wdt` (patched to warm reset so ramoops survives) takes it over, but the
kernel no longer pets it: `/init` forks a small daemon that owns
`/dev/watchdog` and only sends keepalives while the host keeps writing to the
second ACM port (`/dev/ttyACM1`, gadget `/dev/ttyGS1`).

The port is not a shell, any byte counts as a heartbeat:

```sh
global/harness/2ndstage/host/gkiw-heartbeat /dev/ttyACM1
```

With the default 30 s timeout and 5 s heartbeat window, stopping the host tool,
crashing the harness or unplugging USB resets the phone back into the second
stage in about 35 s. ModemManager may briefly probe the new port at
enumeration, which delays that by ~20 s but does not keep it alive.

The timeout is `GKIW_WDT_TIMEOUT` in `global/harness/linux/init.c`.
