# Linux USB ACM shell

The first-boot evidence path is a USB ACM serial gadget, not ssh:

- no network stack, DHCP or NetworkManager;
- no sshd, host keys or auth;
- no root needed on the host beyond opening the USB device;
- the host can run commands as soon as `/dev/ttyACM0` appears.

It is a root shell in a development initramfs. Never ship it.

## Kernel side

The G12A Linux fragment enables:

```text
CONFIG_USB_GADGET=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_LIBCOMPOSITE=y
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_USB_DWC2=y
CONFIG_USB_DWC2_DUAL_ROLE=y
```

`init.c` mounts configfs, creates an ACM function, binds the first UDC, opens
`/dev/ttyGS0` and execs a busybox shell on it.

## Build

```sh
BUSYBOX=/path/to/aarch64-static-busybox \
    global/harness/linux/build-initramfs.sh
```

Pack it with a Linux `Image` and the dev DT as usual (see
`docs/bringup.md`). The resulting boot image is a development image; the
watchdog policy still applies.

## Use

```sh
global/harness/linux/gkiw-console
```

or:

```sh
socat - /dev/ttyACM0,raw,echo=0
```

Evidence that the kernel booted enough to be connectable:

```sh
uname -a
cat /proc/version
cat /proc/device-tree/compatible
dmesg
lsmod
```

The shell answering is the gate. Until it does, the 60 s hardware watchdog armed
by the 2ndstage is the recovery path and Linux must not take over the watchdog.
Once the ACM shell is reliable, you can enable `MESON_WATCHDOG` and a petting
daemon if you want long interactive sessions; otherwise leave it off and let a
hung kernel reset.

## Limitations

- Development only: unauthenticated root shell.
- Requires a UDC and a peripheral-capable port; the G12A DWC2 port is used.
- The UART still carries early boot output; the ACM shell starts after the
  initramfs has mounted configfs.
