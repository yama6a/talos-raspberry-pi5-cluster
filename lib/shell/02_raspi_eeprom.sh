#!/usr/bin/env bash
# Builds a reusable Pi 5 EEPROM-flashing SD card that sets the boot order and enables the PCIe probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
WORKDIR="$(mktemp -d)/rpi-eeprom-build"
BOOT_ORDER="0xf461"                  # SD -> NVMe -> USB -> retry
SD_LABEL="RPIBOOT"                   # FAT32 volume name (<=11 chars, UPPERCASE)

# ---- state ----
PIEEPROM_SRC=""   # set by pick_bootloader_image
RECOVERY_SRC=""
SD_DISK=""        # set by prompt_for_sd_card

# ---- functions ----

clone_firmware_repo() {
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"
  rm -rf rpi-eeprom
  say "cloning rpi-eeprom repo to ${WORKDIR}"
  git clone --depth 1 https://github.com/raspberrypi/rpi-eeprom.git
  cd rpi-eeprom
}

# Newest stable 2712 image; beta and old are skipped so this lands on a release build.
pick_bootloader_image() {
  PIEEPROM_SRC="$(find . -path '*2712*' -name 'pieeprom-*.bin' ! -path '*beta*' ! -path '*old*' | sort | tail -n1)"
  [ -n "${PIEEPROM_SRC}" ] || die "no 2712 pieeprom image found"
  RECOVERY_SRC="$(dirname "${PIEEPROM_SRC}")/recovery.bin"
  say "using bootloader: ${PIEEPROM_SRC}"
}

# Strip any existing copies of our two keys, then append ours; the rest of the default config is preserved.
write_eeprom_config() {
  python3 ./rpi-eeprom-config "${PIEEPROM_SRC}" > boot.conf
  grep -v -E '^(BOOT_ORDER|PCIE_PROBE)=' boot.conf > boot.conf.new || true
cat >> boot.conf.new <<EOF
BOOT_ORDER=${BOOT_ORDER}
PCIE_PROBE=1
EOF
  mv boot.conf.new boot.conf
  echo "----- final EEPROM config -----"; cat boot.conf; echo "-------------------------------"
}

# pieeprom.bin, not .upd: recovery.bin flashes and then stops without disabling the card, so one card does
# every node. pieeprom.sig must hold the image's hex sha256 on the first line and nothing else.
build_card_payload() {
  python3 ./rpi-eeprom-config --config boot.conf --out pieeprom.bin "${PIEEPROM_SRC}"
  shasum -a 256 pieeprom.bin | cut -d' ' -f1 > pieeprom.sig
  mkdir -p ../card
  cp "${RECOVERY_SRC}" pieeprom.bin pieeprom.sig ../card/
  say "card payload ready:"; ls -l ../card
}

# The WHOLE-DISK id (/dev/disk4), not a partition (/dev/disk4s1).
prompt_for_sd_card() {
  diskutil list
  read -r -p ">> enter SD card disk id (e.g. /dev/disk4): " SD_DISK
  diskutil info "${SD_DISK}" >/dev/null 2>&1 || die "'${SD_DISK}' is not a disk"
}

confirm_erase() {
  diskutil info "${SD_DISK}" | grep -E 'Device / Media Name|Disk Size|Removable|Protocol' || true
  confirm_word_always YES "ERASE ${SD_DISK} and write the EEPROM card?" \
    || { echo "aborted."; exit 1; }
}

write_card() {
  diskutil eraseDisk FAT32 "${SD_LABEL}" MBRFormat "${SD_DISK}"
  cp ../card/recovery.bin ../card/pieeprom.bin ../card/pieeprom.sig "/Volumes/${SD_LABEL}/"
  sync
  diskutil eject "${SD_DISK}"
}

print_next_steps() {
  say "Done. Card ejected."
  echo "   Next (physical): boot each Pi 5 from this card."
  echo "   success = rapid green LED blink (green screen on HDMI); failure = red + blink code."
  echo "   then power off, remove the card, move to the next board."
}

# ---- main ----

clone_firmware_repo
pick_bootloader_image
write_eeprom_config
build_card_payload

# Destructive from here.
prompt_for_sd_card
confirm_erase
write_card
print_next_steps
