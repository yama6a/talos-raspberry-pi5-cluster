#!/usr/bin/env bash
# DANGEROUS: wipes every node back to maintenance mode, including all persistent data on disk.
# Recovery depends on what the workloads back up elsewhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
# Each label must match a volume the machine config still declares, or the whole reset fails. For a dropped
# volume use `talosctl wipe disk <part> --drop-partition`. BOOT, EFI and META stay, so no reflash is needed.
WIPE_LABELS="STATE,EPHEMERAL,u-storage"
RESET_TIMEOUT="10m" # per node. talosctl's default retries silently for 30m
MAINT_WAIT=300      # secs for a reset worker to answer the maintenance API again

# ---- functions ----

# Resets the group in parallel. Output goes through sed for the IP prefix, so PIPESTATUS[0] carries talosctl's exit.
reset_group() {
  local label="$1"
  shift
  local ips=("$@") pids=() fail=0 ip i rc
  say "resetting ${#ips[@]} ${label} node(s) in parallel (${WIPE_LABELS}) to maintenance mode"
  for ip in "${ips[@]}"; do
    (
      talosctl reset -e "$ip" -n "$ip" \
        --system-labels-to-wipe "$WIPE_LABELS" \
        --timeout "$RESET_TIMEOUT" \
        --reboot --graceful=false 2>&1 | sed "s/^/[$ip] /"
      exit "${PIPESTATUS[0]}"
    ) &
    pids+=("$!")
  done
  # Waits on each, so every node in the group is reported.
  for i in "${!ips[@]}"; do
    if wait "${pids[$i]}"; then
      say "[${ips[$i]}] reset OK"
    else
      rc=$?
      echo ">> [${ips[$i]}] reset failed (exit $rc)" >&2
      fail=1
    fi
  done
  return "$fail"
}

# Workers first, and back in maintenance mode, before the control plane. A worker's apid needs trustd on a
# control-plane node, so a control-plane wipe during a worker's reset strands it until a physical reflash.
reset_workers() {
  local ip
  [ "${#WORKER_IPS[@]}" -gt 0 ] || return 0
  reset_group worker "${WORKER_IPS[@]}" \
    || die "a worker failed to reset. The control plane is still up and untouched, so fix that node and re-run."
  # Maintenance mode, not the reset call returning, proves the worker no longer needs the control plane.
  say "confirming every worker is back on the maintenance API before the control plane goes"
  for ip in "${WORKER_IPS[@]}"; do
    printf '   %-16s ' "$ip"
    wait_talos_api "$ip" "$MAINT_WAIT" insecure || {
      echo "timed out"
      die \
        "${ip} did not come back in maintenance mode within ${MAINT_WAIT}s. The control plane is still up. Fix
       this node and re-run. Do not reset the control plane first, or this node loses its apid and needs a reflash."
    }
    echo "maintenance"
  done
}

reset_control_plane() {
  reset_group control-plane "${CP_IPS[@]}" \
    || {
      echo ">> one or more control-plane nodes failed to reset." >&2
      exit 1
    }
}

# ---- main ----

confirm_word_always YES "Destroy the whole Talos cluster and wipe all persistent data (u-storage)?" \
  || {
    echo "aborted, nothing destroyed."
    exit 0
  }

reset_workers
reset_control_plane
say "all nodes reset to maintenance mode."
