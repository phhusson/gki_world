# Archos 50f Helium boot evidence

Captured over the USB ACM shell from a `fastboot boot` of the ARMv7 Linux
image, with the U-Boot stage in the `boot` partition and the backlight off.

- `version`: `uname -a` and `/proc/version`
- `compatible`: `/proc/device-tree/compatible`
- `uptime`: uptime at capture time
- `udc`: `/sys/class/udc` (ci_hdrc.0)
- `regulators`: PM8909 RPM regulators and their state (L7 + L13 for the PHY)
- `watchdog`: the PM8916 PON watchdog device bound to `pm8916-wdt`
- `apcs_mailbox`: the APCS mailbox bound to `qcom_apcs_ipc`
- `watchdog-heartbeat`: userspace watchdog / host heartbeat timeline
- `battery-2ndstage`: U-Boot PM8909 VADC battery read and calibration
- `peripherals`: eMMC, keys, touchscreen and accelerometer bring-up
- `dmesg`: kernel log from the ACM shell

The RPM/APCS mailbox now probes, so the USB PHY uses the real PM8909 L7/L13
rails. `devices_deferred` is empty. The A53 PLL block must stay disabled (it
hangs this SoC) and the APCS node drops its clock properties so fw_devlink does
not block the mailbox.

The PMIC watchdog is armed by the second stage and owned from userspace: the
phone resets unless the host keeps sending heartbeats on `/dev/ttyACM1`.
