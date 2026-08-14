#!/usr/bin/env bash
# Verifies every node after flashing (03a) and booting from its NVMe, while still in MAINTENANCE mode.
# The last per-node gate before cluster bring-up (03c).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
EXPECT_TALOS="$TALOS_VERSION"                # our build's Talos version (a local "-dirty" build matches too)
EXPECT_CMDLINE="console=ttyAMA0,115200"      # rpi5 overlay signature in the kernel cmdline

# ---- functions ----

# Insecure and with no talosconfig, because these nodes are in maintenance and are not a cluster yet. Distinct
# from the lib's talosctl(), which mounts the cluster talosconfig.
tctl() {
  docker run --rm --network host "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

pull_talosctl() {
  docker info >/dev/null 2>&1 || die "docker not running (needed for the talosctl container)"
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null
}

# The Talos API is the verdict; ICMP is only context. A Pi 5 in maintenance drops sparse pings while TCP stays
# solid, because EEE still powers the PHY down between packets until 03d turns it off, and 03d runs after 03c.
# Measured 20-40% single-packet loss on these NICs against 0% on the x86 node, so a lost ping must not skip
# the real checks. Three packets rather than one, for the same reason.
check_reachable() {
  local host="$1" ip="$2" icmp
  if ping -c3 -t10 "$ip" >/dev/null 2>&1; then icmp="ok"; else icmp="no reply"; fi
  if nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1; then
    ok "reachable, Talos API port ${API_PORT} open (icmp: ${icmp})"
    [ "$icmp" = "ok" ] || warn "${host} did not answer ICMP; harmless here, the API is what the bring-up needs"
    return 0
  fi
  bad "unreachable: Talos API port ${API_PORT} closed (icmp: ${icmp}), skipping the rest for this node"
  return 1
}

# Catches a drive flashed from a stale cached image, on any hardware type.
check_talos_version() {
  local ip="$1" out rc sv
  out="$(tctl -n "$ip" version --insecure 2>&1)"; rc=$?
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

# Asserted by NAME only on rpi5, where end0 is fixed and the VIP binds to it. On any other type the name comes
# from firmware and we hold no expectation, so print what it has and let a human read it.
check_nic() {
  local ip="$1" type="$2" out rc state
  out="$(tctl -n "$ip" get links --insecure 2>&1)"; rc=$?
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
    # Printed, not parsed: the KIND column is empty for a physical NIC, so the field count differs per row and
    # picking one out by position is guesswork.
    ok "links readable, no name asserted on ${type}. Its wired NIC is one of:"
    echo "$out" | sed 's/^/           /'
  fi
}

check_install_disk() {
  local ip="$1" out rc
  out="$(tctl -n "$ip" get disks --insecure 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -qE "[[:space:]/]${EXPECT_DISK}([[:space:]]|\$)"; then
    ok "NVMe /dev/${EXPECT_DISK} seen"
  elif [ $rc -ne 0 ]; then
    bad "get disks --insecure failed: $(echo "$out" | tail -1)"
  else
    bad "/dev/${EXPECT_DISK} not found in disks"
  fi
}

# Proves the overlay's kernel booted rather than stock arm64. dmesg needs certs, so check the kernel cmdline
# for the overlay's signature arg instead, which is maintenance-mode safe. A factory image has no equivalent
# signature worth asserting, so other hardware types get nothing to check.
check_rpi5_kernel() {
  local ip="$1" out rc
  out="$(tctl -n "$ip" get kernelcmdlines -o yaml --insecure 2>&1)"; rc=$?
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
  check_install_disk "$ip"
  [ "$type" = rpi5 ] && check_rpi5_kernel "$ip"
  return 0
}

print_result() {
  if [ "$FAIL" -eq 0 ]; then
    echo "All nodes good. Next: cluster bring-up, ./03c_talos_cluster_config.sh"
  else
    echo "Some checks failed. This script runs talosctl via the container to avoid the"
    echo "native macOS 'no route to host' gotcha."
    echo "Node never appears / NIC or NVMe missing -> see Troubleshooting in 03_operating_system.md."
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
