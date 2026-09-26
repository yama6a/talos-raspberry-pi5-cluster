# EEPROM runbook

The reasons behind these settings are in [02_raspi_eeprom.md](../02_raspi_eeprom.md).

## Build the card

Runs on macOS.

1. Insert a microSD card into your laptop.
2. Build the card:

   ```bash
   make build-eeprom-card
   ```

   The script picks the newest stable Pi 5 bootloader, sets `BOOT_ORDER` and `PCIE_PROBE`, prints the final
   config and asks for the card's disk id.
3. Enter the whole-disk id, for example `/dev/disk4`, not a partition such as `/dev/disk4s1`.
4. Type `YES` to erase the card. The script writes it and ejects it.

## Flash each board

The NVMe does not need to be installed yet. This only touches the EEPROM.

1. Insert the card into the Pi and power on.
2. Wait for the result:
   - Success: the green LED blinks fast, and HDMI shows a green screen.
   - Failure: red LED and a blink code.
3. Power off, remove the card, and move to the next board.

Then flash the Talos image onto each NVMe. See the [operating system runbook](03_operating_system.md).
