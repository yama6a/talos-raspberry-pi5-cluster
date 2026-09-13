#!/usr/bin/env bash
# Downloads a node's Talos image and writes it to an NVMe SSD over a USB adapter, once per drive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
03a_talos_image_flasher.sh [<host>]        (or: make flash-talos-nvme NODE=<host>)
  <host>   whose IMAGE to write; omit it to pick from the inventory interactively

The drive is not bound to that hostname, only the image is, so one run covers every drive of the same
hardware type. Where the image comes from is the node's imageSource in inventory.yaml:
  github-release   the TALOS_IMAGE_REPO release TALOS_IMAGE_RELEASE pins, verified against sha256sums.txt
  image-factory    factory.talos.dev, built from that node's imageSchematic, no checksum published
EOF
}

# ---- state ----
NODE=""          # set by resolve_node
IMAGE_SOURCE=""
IMAGE_FILE=""
SRC=""           # set by resolve_image_url
DIR=""
RAW_XZ=""
RAW=""           # set by decompress_image
DISK=""          # set by prompt_for_nvme

# ---- functions ----

# Deliberately asks rather than defaulting: the wrong pick writes another architecture's image, which boots
# to nothing.
choose_node_interactively() {
  local i h pick
  echo
  echo "Which node's image? The drive is not tied to the node, so any node of the same type will do."
  for i in "${!ALL_HOSTS[@]}"; do
    h="${ALL_HOSTS[$i]}"
    printf '  %2d) %-14s %-16s %-12s %s\n' \
      "$((i+1))" "$h" "${NODE_TYPE[$h]}" "${NODE_ROLE[$h]}" "${NODE_IMAGE_FILE[$h]}"
  done
  echo
  while :; do
    read -r -p ">> number [1-${#ALL_HOSTS[@]}]: " pick \
      || die "no input to read (not a terminal?); name the node instead: make flash-talos-nvme NODE=<hostname>"
    case "$pick" in
      ''|*[!0-9]*) echo "   '${pick}' is not a number." ;;
      *) if [ "$pick" -ge 1 ] && [ "$pick" -le "${#ALL_HOSTS[@]}" ]; then
           NODE="${ALL_HOSTS[$((pick-1))]}"; return 0
         else
           echo "   ${pick} is out of range."
         fi ;;
    esac
  done
}

resolve_node() {
  NODE="${1:-}"
  [ -n "$NODE" ] || choose_node_interactively
  [ -n "${NODE_ROLE[$NODE]:-}" ] || die "unknown node '${NODE}': inventory.yaml has ${ALL_HOSTS[*]}"
  IMAGE_SOURCE="${NODE_IMAGE_SOURCE[$NODE]}"
  IMAGE_FILE="${NODE_IMAGE_FILE[$NODE]}"
}

# The cache dir is keyed by whatever identifies the build, so a version bump lands in a fresh dir and
# re-flashing a second drive of the same type re-downloads nothing.
resolve_image_url() {
  local schematic_id
  case "$IMAGE_SOURCE" in
    github-release)
      # The raw image is a release ASSET on github.com, while the installer 03e uses is a CONTAINER on
      # ghcr.io. Same repo, two hosts, hence stripping the registry prefix off TALOS_IMAGE_REPO.
      SRC="https://github.com/${TALOS_IMAGE_REPO#ghcr.io/}/releases/download/${TALOS_IMAGE_RELEASE}/${IMAGE_FILE}"
      DIR="${IMAGE_CACHE}/${TALOS_IMAGE_RELEASE}"
      ;;
    image-factory)
      schematic_id="$(factory_schematic_id "${NODE_IMAGE_SCHEMATIC[$NODE]}")"
      SRC="https://${FACTORY_HOST}/image/${schematic_id}/${TALOS_VERSION}/${IMAGE_FILE}"
      DIR="${IMAGE_CACHE}/factory-${TALOS_VERSION}-${schematic_id:0:12}"
      ;;
  esac
  RAW_XZ="${DIR}/${IMAGE_FILE}"
  mkdir -p "$DIR"
  say "${NODE}: ${NODE_TYPE[$NODE]}, imageSource ${IMAGE_SOURCE}"
  echo "   ${SRC}"
}

download_image() {
  [ -f "$RAW_XZ" ] && return 0
  say "downloading ${IMAGE_FILE} (~100 MB)"
  curl -fL --retry 3 --progress-bar -o "${RAW_XZ}.part" "$SRC" \
    || die "download failed: ${SRC} (does that release/schematic exist?)"
  mv "${RAW_XZ}.part" "$RAW_XZ"
}

# Only the release publishes a checksum file.
verify_checksum() {
  local sums_url want got
  if [ "$IMAGE_SOURCE" != github-release ]; then
    warn "${FACTORY_HOST} publishes no sha256sums.txt, so this image is unverified beyond HTTPS"
    return 0
  fi
  sums_url="https://github.com/${TALOS_IMAGE_REPO#ghcr.io/}/releases/download/${TALOS_IMAGE_RELEASE}/sha256sums.txt"
  curl -fsSL --retry 3 -o "${DIR}/sha256sums.txt" "$sums_url" || die "cannot fetch ${sums_url}"
  say "verifying checksum"
  want="$(awk -v a="$IMAGE_FILE" '$2 ~ a {print $1; exit}' "${DIR}/sha256sums.txt")"
  [ -n "$want" ] || die "sha256sums.txt names no ${IMAGE_FILE}"
  got="$(shasum -a 256 "$RAW_XZ" | awk '{print $1}')"
  [ "$want" = "$got" ] || die "checksum mismatch for ${RAW_XZ}: got ${got}, expected ${want}. Delete it and re-run."
  echo "   sha256 ok (${got})"
}

decompress_image() {
  RAW="${RAW_XZ%.xz}"
  if [ ! -f "$RAW" ] || [ "$RAW_XZ" -nt "$RAW" ]; then
    say "decompressing -> $RAW"
    xz -dkf "$RAW_XZ"
  fi
  ls -lh "$RAW"
}

# The WHOLE-DISK id (/dev/disk6), not a partition (/dev/disk6s1).
prompt_for_nvme() {
  diskutil list
  read -r -p ">> enter NVMe disk id (e.g. /dev/disk6): " DISK \
    || die "no input to read (not a terminal?); this step needs a human to identify the drive"
  diskutil info "${DISK}" >/dev/null 2>&1 || die "'${DISK}' is not a disk"
}

confirm_erase() {
  diskutil info "${DISK}" | grep -E 'Device / Media Name|Disk Size|Protocol|Removable' || true
  confirm_word_always YES "ERASE ${DISK} and write the ${NODE_TYPE[$NODE]} Talos image (${IMAGE_FILE})?" \
    || { echo "aborted."; exit 1; }
}

write_drive() {
  local rdisk="/dev/r${DISK##*/}"   # the raw device is much faster on macOS
  diskutil unmountDisk "${DISK}"
  say "writing to ${rdisk} ... (press Ctrl-T for progress)"
  sudo dd if="${RAW}" of="${rdisk}" bs=4M
  sync
  diskutil eject "${DISK}"
}

print_next_steps() {
  say "Done. ${DISK} ejected."
  echo "   Next: slot the SSD into its ${NODE_TYPE[$NODE]} and power on (a Pi needs NO SD card) -> maintenance mode."
  echo "   Repeat for each remaining ${NODE_TYPE[$NODE]} drive; a different hardware type needs its own NODE=."
}

# ---- main ----

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

require curl xz
resolve_node "$@"
resolve_image_url
download_image
verify_checksum
decompress_image

# Destructive from here.
prompt_for_nvme
confirm_erase
write_drive
print_next_steps
