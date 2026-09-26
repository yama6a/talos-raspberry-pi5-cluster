# Pi 5 EEPROM boot settings

Every Pi 5 gets the same bootloader firmware and boot config before the OS goes on, whatever version it shipped
with. Procedures are in the [EEPROM runbook](runbooks/02_raspi_eeprom.md).

- One reusable SD card flashes the latest stable bootloader and a known config onto each board. That also levels
  every board onto the same firmware version.
- A custom card, because the Pi Imager's "NVMe/USB Boot" preset writes a fixed config. It cannot set
  `PCIE_PROBE` or the boot order.
- Once every board is flashed, the card has no further job.

## The settings

| Setting | Does | Why |
|---|---|---|
| `BOOT_ORDER=0xf461` | tries SD, then NVMe, then USB, then loops | with no card inserted the board boots NVMe, and a card can always override or recover a node |
| `PCIE_PROBE=1` | makes the bootloader probe PCIe | the RS-P11 is not a HAT+ board and has no ID EEPROM, so without this the firmware may never see the NVMe. With no drive present the cost is a short boot delay |
