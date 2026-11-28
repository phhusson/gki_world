# Archos 50f Helium boot evidence

Captured over the USB ACM shell from a `fastboot boot` of the ARMv7 Linux
image, with the U-Boot stage in the `boot` partition and the backlight off.

- `version`: `uname -a` and `/proc/version`
- `compatible`: `/proc/device-tree/compatible`
- `udc`: `/sys/class/udc` (ci_hdrc.0)
- `dmesg`: kernel log from the ACM shell

The RPM/APCS mailbox is still deferred (`qcom-smsm`/`qcom-smd` errors); USB is
unblocked with fixed PHY supplies. The PMIC PON watchdog is armed by the
second stage and petted by `pm8916_wdt`; ramoops is at `0x9d000000`.
