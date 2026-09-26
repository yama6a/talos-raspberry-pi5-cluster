#!/usr/bin/env bash
# Checks every node after 03a, booted from its NVMe and still in maintenance mode. The last gate before 03c.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
EXPECT_TALOS="$TALOS_VERSION"           # a local "-dirty" build matches too
EXPECT_CMDLINE="console=ttyAMA0,115200" # the rpi5 overlay's mark in the kernel cmdline

# ---- functions ----

# No talosconfig, unlike talosctl() in common.sh, because these nodes are not a cluster yet.
tctl() {
  docker run --rm --network host "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

pull_talosctl() {
  docker info > /dev/null 2>&1 || die "docker not running (needed for the talosctl container)"
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" > /dev/null
}

# The Talos API decides. Until 03d turns EEE off, a Pi 5 drops sparse pings while TCP works, so a lost ping
# must not skip the real checks. Three packets for the same reason.
check_reachable() {
  local host="$1" ip="$2" icmp
  if ping -c3 -t10 "$ip" > /dev/null 2>&1; then icmp="ok"; else icmp="no reply"; fi
  if nc -z -G2 "$ip" "$API_PORT" > /dev/null 2>&1; then
    ok "reachable, Talos API port ${API_PORT} open (icmp: ${icmp})"
    [ "$icmp" = "ok" ] || warn "${host} did not answer ICMP. Harmless here, the bring-up needs only the API"
    return 0
  fi
  bad "unreachable: Talos API port ${API_PORT} closed (icmp: ${icmp}). Skipping the other checks for this node"
  return 1
}

# Catches a drive flashed from a stale cached image, on any hardware type.
check_talos_version() {
  local ip="$1" out rc sv
  out="$(tctl -n "$ip" version --insecure 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] || ! echo "$out" | grep -q 'Server:'; then
    bad "version --insecure failed: $(echo "$out" | tail -1)"
    return 0
  fi
  sv="$(echo "$out" | awk '/Server:/{s=1} s&&/Tag:/{print $2; exit}')"
  if [ "${sv%-dirty}" = "$EXPECT_TALOS" ]; then
    ok "Talos ${sv}, the version versions.env pins"
  else
    ok "Talos API responds (server ${sv:-?})"
    printf '         \033[33mnote:\033[0m server %s != expected %s\n' "${sv:-?}" "$EXPECT_TALOS"
  fi
}

# Checked by name on rpi5 only, where end0 is fixed. Elsewhere the name comes from firmware, so print the links.
check_nic() {
  local ip="$1" type="$2" out rc state indent='           '
  out="$(tctl -n "$ip" get links --insecure 2>&1)"
  rc=$?
  if [ $rc -ne 0 ]; then
    bad "get links --insecure failed: $(echo "$out" | tail -1)"
  elif [ "$type" = rpi5 ]; then
    if echo "$out" | grep -qE "[[:space:]]${EXPECT_NIC}([[:space:]]|\$)"; then
      state="$(echo "$out" | grep -E "[[:space:]]${EXPECT_NIC}([[:space:]]|\$)" | grep -oiwE 'up|down' | head -1)"
      ok "NIC ${EXPECT_NIC} present${state:+ (${state})}"
    else
      bad "NIC ${EXPECT_NIC} not found in links"
    fi
  else
    # Printed, not parsed: KIND is empty for a physical NIC, so the column count differs per row.
    ok "links readable, no name asserted on ${type}. Its wired NIC is one of:"
    printf '%s\n' "${indent}${out//$'\n'/$'\n'${indent}}"
  fi
}

check_install_disk() {
  local ip="$1" disk="$2" out rc
  out="$(tctl -n "$ip" get disks --insecure 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -qE "[[:space:]/]${disk##*/}([[:space:]]|\$)"; then
    ok "install disk ${disk} seen"
  elif [ $rc -ne 0 ]; then
    bad "get disks --insecure failed: $(echo "$out" | tail -1)"
  else
    # Printed because the fix is to copy one of these into the node's installDisk.
    bad "install disk ${disk} (inventory installDisk) not found. The node has:"
    echo "$out" | tail -n +2 | sed 's/^/           /'
  fi
}

# Proves the overlay's kernel booted, not stock arm64. dmesg needs certs in maintenance mode, the cmdline does not.
check_rpi5_kernel() {
  local ip="$1" out rc
  out="$(tctl -n "$ip" get kernelcmdlines -o yaml --insecure 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -qF "$EXPECT_CMDLINE"; then
    ok "Pi 5 overlay/kernel booted (cmdline has ${EXPECT_CMDLINE})"
  elif [ $rc -ne 0 ]; then
    bad "get kernelcmdlines --insecure failed: $(echo "$out" | tail -1)"
  else
    bad "rpi5 overlay arg '${EXPECT_CMDLINE}' not in kernel cmdline"
  fi
}

verify_node() {
  local host="$1" ip="${NODE_IP[$1]}" type="${NODE_TYPE[$1]}"
  echo ""
  echo "=============== ${host}  ${ip}  (${type}) ==============="
  check_reachable "$host" "$ip" || return 0
  check_talos_version "$ip"
  check_nic "$ip" "$type"
  check_install_disk "$ip" "${NODE_INSTALL_DISK[$1]}"
  [ "$type" = rpi5 ] && check_rpi5_kernel "$ip"
  return 0
}

print_result() {
  if [ "$FAIL" -eq 0 ]; then
    echo "All nodes good. Next: cluster bring-up, make init-talos"
  else
    echo "Some checks failed. This script runs talosctl in a container, so macOS 'no route to host' is not the cause."
    echo "For a missing node, NIC or install disk, see Troubleshooting in docs/runbooks/03_operating_system.md."
  fi
}

# ---- main ----

pull_talosctl

for host in "${ALL_HOSTS[@]}"; do
  verify_node "$host"
done

summary
print_result
[ "$FAIL" -eq 0 ]
