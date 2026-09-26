#!/usr/bin/env bash
# Builds a reusable Pi 5 EEPROM-flashing SD card that sets the boot order and enables the PCIe probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
WORKDIR="$(mktemp -d)/rpi-eeprom-build"
BOOT_ORDER="0xf461" # SD, then NVMe, then USB, then retry
SD_LABEL="RPIBOOT"  # FAT32 volume name, at most 11 uppercase characters

# ---- state ----
PIEEPROM_SRC="" # set by pick_bootloader_image
RECOVERY_SRC=""
SD_DISK="" # set by prompt_for_sd_card

# ---- functions ----

clone_firmware_repo() {
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"
  rm -rf rpi-eeprom
  say "cloning rpi-eeprom repo to ${WORKDIR}"
  git clone --depth 1 https://github.com/raspberrypi/rpi-eeprom.git
  cd rpi-eeprom
}

# The newest stable 2712 image. Skips beta and old.
pick_bootloader_image() {
  PIEEPROM_SRC="$(find . -path '*2712*' -name 'pieeprom-*.bin' ! -path '*beta*' ! -path '*old*' | sort | tail -n1)"
  [ -n "${PIEEPROM_SRC}" ] || die "no 2712 pieeprom image found"
  RECOVERY_SRC="$(dirname "${PIEEPROM_SRC}")/recovery.bin"
  say "using bootloader: ${PIEEPROM_SRC}"
}

# Replaces our two keys and keeps the rest of the default config.
write_eeprom_config() {
  python3 ./rpi-eeprom-config "${PIEEPROM_SRC}" > boot.conf
  grep -v -E '^(BOOT_ORDER|PCIE_PROBE)=' boot.conf > boot.conf.new || true
  cat >> boot.conf.new << EOF
BOOT_ORDER=${BOOT_ORDER}
PCIE_PROBE=1
EOF
  mv boot.conf.new boot.conf
  echo "----- final EEPROM config -----"
  cat boot.conf
  echo "-------------------------------"
}

# pieeprom.bin, not .upd: recovery.bin then leaves the card usable, so one card flashes every node.
# pieeprom.sig must hold only the image's hex sha256, on the first line.
build_card_payload() {
  python3 ./rpi-eeprom-config --config boot.conf --out pieeprom.bin "${PIEEPROM_SRC}"
  shasum -a 256 pieeprom.bin | cut -d' ' -f1 > pieeprom.sig
  mkdir -p ../card
  cp "${RECOVERY_SRC}" pieeprom.bin pieeprom.sig ../card/
  say "card payload ready:"
  ls -l ../card
}

# The whole-disk id (/dev/disk4), not a partition (/dev/disk4s1).
prompt_for_sd_card() {
  diskutil list
  read -r -p ">> enter SD card disk id (e.g. /dev/disk4): " SD_DISK
  diskutil info "${SD_DISK}" > /dev/null 2>&1 || die "'${SD_DISK}' is not a disk"
}

confirm_erase() {
  diskutil info "${SD_DISK}" | grep -E 'Device / Media Name|Disk Size|Removable|Protocol' || true
  confirm_word_always YES "ERASE ${SD_DISK} and write the EEPROM card?" \
    || {
      echo "aborted."
      exit 1
    }
}

write_card() {
  diskutil eraseDisk FAT32 "${SD_LABEL}" MBRFormat "${SD_DISK}"
  cp ../card/recovery.bin ../card/pieeprom.bin ../card/pieeprom.sig "/Volumes/${SD_LABEL}/"
  sync
  diskutil eject "${SD_DISK}"
}

print_next_steps() {
  say "Done. Card ejected."
  echo "   Next: boot each Pi 5 from this card."
  echo "   Success: the green LED blinks fast, and HDMI shows green. Failure: red LED and a blink code."
  echo "   Then power off, remove the card and move to the next board."
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
