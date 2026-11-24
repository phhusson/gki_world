# Archos 50b Helium 4G harness notes

- The stock MSM8916 bootloader does not boot a mainline device tree directly.
  lk2nd is the first stage: flash it to `boot`, then boot the gki_world image
  through lk2nd's fastboot interface.
- There is no `ac50bhe` dump on `dumps.tadiphone.dev` yet. Capture the stock
  `boot`, `system`/`super` and `persist` partitions from the device, or add a
  dump, before filling in `bootimg.yaml` and `firmware.yaml`.
- Extract the vendor device tree with `dtc -I dtb -O dts` and use it to recover
  the panel, touchscreen, sensors, SD card regulator and key GPIOs. Do not copy
  another MSM8916 device's values.
- `board.dts` is intentionally minimal: console, eMMC and USB detect only.
- Watchdog: MSM8916 has no mainline watchdog node yet, so a wedged boot may hang
  instead of resetting. Keep `CONFIG_PANIC_TIMEOUT` set and use the reset button.
