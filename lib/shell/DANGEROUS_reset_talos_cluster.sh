#!/usr/bin/env bash
# DANGEROUS: wipes every node back to maintenance, including all on-disk persistent data.
# Node state only, so whether a reset is recoverable depends on what the workloads back up elsewhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
# Every label must resolve to a live VolumeStatus, so the machine config must still DECLARE that volume: the
# reset looks each one up by ID and fails the whole call if one is missing. A label for a volume already
# dropped from the config belongs in `talosctl wipe disk <part> --drop-partition` instead.
# BOOT/EFI/META are kept, so nodes reboot straight to maintenance with no reflash.
WIPE_LABELS="STATE,EPHEMERAL,u-storage"
RESET_TIMEOUT="10m"   # per node. talosctl's own default is 30m, which just retries silently for half an hour
MAINT_WAIT=300        # secs for a reset worker to answer the maintenance API again

# ---- functions ----

# Resets every node in the group at once, then waits for all of them. Output is prefixed with the node IP so
# the interleaved streams stay readable; that prefixing pipes through sed, and a pipeline's exit code is sed's,
# so PIPESTATUS[0] is how we still see whether talosctl failed.
reset_group() {
  local label="$1"; shift
  local ips=("$@") pids=() fail=0 ip i rc
  say "resetting ${#ips[@]} ${label} node(s) in parallel (${WIPE_LABELS}) -> maintenance"
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
  # Wait on each, not the first failure, so every node in the group is reported.
  for i in "${!ips[@]}"; do
    if wait "${pids[$i]}"; then
      say "[${ips[$i]}] reset OK"
    else
      rc=$?
      echo ">> [${ips[$i]}] reset FAILED (exit $rc)" >&2
      fail=1
    fi
  done
  return "$fail"
}

# Workers FIRST, and all the way back into maintenance, before the control plane is touched. A worker holds no
# CA key of its own: its apid gets a server certificate signed by trustd, which runs ONLY on control-plane
# nodes. So wiping the control plane while a worker is mid-reset kills that worker's apid for good, its reset
# can never finish, and no API is left to retry it. Recovering that needs a physical reflash.
reset_workers() {
  local ip
  [ "${#WORKER_IPS[@]}" -gt 0 ] || return 0
  reset_group worker "${WORKER_IPS[@]}" \
    || die "a worker failed to reset. The control plane is still UP and untouched, so fix that node and re-run."
  # Waiting for maintenance rather than for the reset call to return is the point: the guarantee we need is
  # that the worker no longer depends on the control plane at all.
  say "confirming every worker is back on the maintenance API before the control plane goes"
  for ip in "${WORKER_IPS[@]}"; do
    printf '   %-16s ' "$ip"
    wait_talos_api "$ip" "$MAINT_WAIT" insecure || { echo "TIMEOUT"; die \
      "${ip} did not come back in maintenance within ${MAINT_WAIT}s. The control plane is still UP: fix this
       node and re-run. Do NOT reset the control plane first, or this node loses its apid and needs a reflash."; }
    echo "maintenance"
  done
}

reset_control_plane() {
  reset_group control-plane "${CP_IPS[@]}" \
    || { echo ">> one or more control-plane nodes failed to reset." >&2; exit 1; }
}

# ---- main ----

confirm_word_always YES "Destroy ENTIRE Talos cluster AND wipe ALL persistent data (u-storage)?" \
  || { echo "skipped destruction (phew!)."; exit 0; }

reset_workers
reset_control_plane
say "all nodes reset -> maintenance."
