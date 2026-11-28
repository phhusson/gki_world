# Archos 50f Helium Linux bringup

Base: `msm8916-mainline/linux`, branch `wip/msm8916/6.18-rc6`. The board tree
`board.dts` is minimal: CPU/memory from the SoC dtsi, peripheral-mode USB
(ci_hdrc + ULPI PHY), PM8909 PWM, ramoops and a reserved marker page. Storage,
display and the modem are not enabled yet.

The USB PHY uses fixed always-on 1.8 V/3.3 V supplies while the RPM/SMD
regulators are still being brought up; LK leaves the PM8909 LDOs on. The
console is the USB ACM gadget built by the shared initramfs.

Build (ARMv7):

```sh
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- qcom_defconfig
./scripts/kconfig/merge_config.sh -m .config \
    device/archos/ac50fhe/linux/config.fragment
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j16 zImage dtbs

BUSYBOX=/path/to/armhf-static-busybox CC=arm-linux-gnueabihf-gcc \
    global/harness/linux/build-initramfs.sh /tmp/gkiw-acm-initramfs.cpio.gz
```

Then wrap `zImage` with `mkbootimg.sh`, putting the DTB in the `second`
section:

```sh
GKIW_BOOTIMG_HEADER_SIZE=0 GKIW_BOOTIMG_COMPRESS=none \
GKIW_BOOTIMG_RAMDISK=/tmp/gkiw-acm-initramfs.cpio.gz \
GKIW_BOOTIMG_SECOND=.../qcom-msm8909-archos-ac50fhe.dtb \
GKIW_BOOTIMG_CMDLINE="maxcpus=1 cpuidle.off=1 ..." \
    global/harness/2ndstage/scripts/mkbootimg.sh zImage linux-boot.img
```

from U-Boot FASTBOOT (not stock LK; LK has no `oem pstore`):

```sh
fastboot boot linux-boot.img
```

The initramfs exposes a root shell on `/dev/ttyACM0` (`1b8e:fada`).

## Known issue

`qcom-smsm`/`qcom-smd` still fail to bind the APCS mailbox
(`b011000.mailbox`), so the RPM regulators and CPU power domains stay
deferred. USB works around this with the fixed supplies above. The APCS
mailbox (`qcom,msm8916-apcs-kpss-global`, `mboxes = <&apcs 0>`) is the next
item to fix.
