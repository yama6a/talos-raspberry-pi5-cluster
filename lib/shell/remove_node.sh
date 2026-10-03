#!/usr/bin/env bash
# Takes one node out of the cluster: moves its data off, drains it, leaves etcd and resets it to maintenance
# mode. BOOT, EFI and META stay, so `make add-node` can join the machine again without a reflash.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
remove_node.sh <host>                      (or: make remove-node NODE=<host>)
  <host>   the node to remove. Omit it to pick from the inventory

Safe to re-run: every step checks before it acts. Edit the node's inventory entry only after this finishes,
because the script reads the node's IP and role from there.
EOF
}

# ---- knobs ----
REPLICATION_HEALTH_TIMEOUT=1800 # secs to wait for PRE_DRAIN_HEALTH_HOOK before each step that moves data
# Keep GRACEFUL_DRAIN_TIMEOUT above a database switchover: its PDB refuses the eviction until the handover ends.
GRACEFUL_DRAIN_TIMEOUT=600 # secs of graceful drain before the force-delete
FORCE_GRACE=20             # secs of grace on the force-delete, so stragglers can flush. 0 kills at once
RESET_TIMEOUT="10m"        # talosctl's default retries silently for 30m
MAINT_WAIT=600             # secs for the node to answer in maintenance mode after the reset

# ---- state ----
NODE="" # set by parse_args or resolve_node
IP=""
ROLE=""
SURVIVOR_IP=""  # a Ready control-plane node. Every etcd call goes to it
NODE_STATE=""   # running | maintenance, set by probe_node_state
REMAINING_CP=() # control-plane IPs other than this node's
HOOK_WARNED=0

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown flag: $1 (see --help)" ;;
      *)
        NODE="$1"
        shift
        ;;
    esac
  done
}

resolve_node() {
  local h
  [ -n "$NODE" ] || {
    printf '  %s\n' "${ALL_HOSTS[@]}"
    read -rp "Node to remove: " NODE
  }
  IP="${NODE_IP[$NODE]:-}"
  [ -n "$IP" ] || die "unknown node '${NODE}': inventory.yaml has ${ALL_HOSTS[*]}"
  ROLE="${NODE_ROLE[$NODE]}"
  for h in "${CP_HOSTS[@]}"; do
    [ "$h" = "$NODE" ] || REMAINING_CP+=("${NODE_IP[$h]}")
  done
  [ "${#REMAINING_CP[@]}" -ge 1 ] || die "${NODE} is the only control-plane node. Removing it removes the cluster"
}

pick_survivor() {
  local h
  for h in "${CP_HOSTS[@]}"; do
    [ "$h" = "$NODE" ] && continue
    if [ "$(kubectl get node "$h" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2> /dev/null)" = "True" ]; then
      SURVIVOR_IP="${NODE_IP[$h]}"
      return 0
    fi
  done
  die "no other control-plane node is Ready. Removing a node needs the rest of the cluster up"
}

# Probed once, so a re-run after the reset skips straight to the cleanup.
probe_node_state() {
  if talosctl -e "$IP" -n "$IP" version > /dev/null 2>&1; then
    NODE_STATE="running"
  elif talosctl -e "$IP" -n "$IP" version --insecure > /dev/null 2>&1; then
    NODE_STATE="maintenance"
  else
    die "${IP} answers neither the Talos API nor maintenance mode. For a dead machine, follow 'Retire a dead node' in docs/runbooks/05_node_recovery.md"
  fi
  say "removing ${NODE} (${IP}, ${ROLE}), now ${NODE_STATE}"
}

etcd_member_id() {
  talosctl -e "$SURVIVOR_IP" -n "$SURVIVOR_IP" etcd members 2> /dev/null \
    | awk -v url="https://${IP}:2380" 'index($0, url) {print $2; exit}'
}

# Two members still form a quorum but survive no further failure. One member is a cluster with no redundancy.
guard_etcd_quorum() {
  local member total remaining
  [ "$ROLE" = controlplane ] || return 0
  member="$(etcd_member_id)"
  [ -n "$member" ] || return 0
  total="$(talosctl -e "$SURVIVOR_IP" -n "$SURVIVOR_IP" etcd members 2> /dev/null | tail -n +2 | grep -c .)"
  remaining=$((total - 1))
  [ "$remaining" -ge 2 ] || die "etcd has ${total} members. Removing ${NODE} leaves ${remaining}. Add a control-plane node first"
  if [ "$remaining" -eq 2 ]; then
    warn "etcd drops from 3 members to 2. Quorum holds, but the next control-plane failure stops the cluster."
    confirm_word_always TWO "Run etcd on 2 members?" || die "aborted, nothing changed"
  fi
}

confirm_removal() {
  echo
  echo "    About to, on ${NODE} (${IP}): move its data off, drain it, reset it to maintenance mode,"
  echo "    and delete its Kubernetes node. The reset wipes ${WIPE_LABELS}."
  [ "$ROLE" = controlplane ] && echo "    It also leaves etcd, because it is a control-plane node."
  if [ -z "$PRE_REMOVE_STORAGE_HOOK" ]; then
    warn "PRE_REMOVE_STORAGE_HOOK is unset, so nothing moves storage data off ${NODE} before the wipe."
  fi
  echo
  confirm_word_always "$NODE" "Remove ${NODE}?" || die "aborted, nothing changed"
}

# The hook returns once the node holds no storage data, so it may run for as long as the rebuilds take.
move_storage_off() {
  [ -n "$PRE_REMOVE_STORAGE_HOOK" ] || return 0
  [ -x "$PRE_REMOVE_STORAGE_HOOK" ] || die "PRE_REMOVE_STORAGE_HOOK is not executable: ${PRE_REMOVE_STORAGE_HOOK}"
  say "moving storage data off ${NODE} ($(basename "$PRE_REMOVE_STORAGE_HOOK"))"
  NODE="$NODE" "$PRE_REMOVE_STORAGE_HOOK" \
    || die "storage data is still on ${NODE}. Nothing was drained or wiped. Fix it and re-run."
}

# A graceful reset makes a control-plane node leave etcd and hand off the VIP before the wipe.
reset_node() {
  say "resetting ${NODE} to maintenance mode (${WIPE_LABELS})"
  talosctl -e "$IP" -n "$IP" reset \
    --graceful=true \
    --system-labels-to-wipe "$WIPE_LABELS" \
    --timeout "$RESET_TIMEOUT" \
    --reboot || die "the reset of ${IP} failed. ${NODE} stays cordoned. Fix it and re-run."
  printf '    waiting for %s in maintenance mode (up to %ss) ' "$IP" "$MAINT_WAIT"
  wait_talos_api "$IP" "$MAINT_WAIT" insecure || {
    echo "timed out"
    die "${IP} did not come back in maintenance mode. Check its console, then re-run."
  }
  echo "ready"
}

# Covers a reset that wiped the node before it could leave etcd.
drop_etcd_member() {
  local member
  [ "$ROLE" = controlplane ] || return 0
  member="$(etcd_member_id)"
  if [ -z "$member" ]; then
    ok "${NODE} is no longer an etcd member"
    return 0
  fi
  talosctl -e "$SURVIVOR_IP" -n "$SURVIVOR_IP" etcd remove-member "$member" > /dev/null 2>&1 \
    || die "could not remove etcd member ${member}. Check quorum on ${SURVIVOR_IP}, then re-run."
  ok "removed etcd member ${member}"
}

delete_k8s_node() {
  kubectl delete node "$NODE" --ignore-not-found > /dev/null || die "could not delete the Kubernetes node ${NODE}"
  ok "Kubernetes node ${NODE} is gone"
}

forget_storage_node() {
  [ -n "$POST_REMOVE_STORAGE_HOOK" ] || return 0
  [ -x "$POST_REMOVE_STORAGE_HOOK" ] || die "POST_REMOVE_STORAGE_HOOK is not executable: ${POST_REMOVE_STORAGE_HOOK}"
  say "dropping the storage layer's record of ${NODE} ($(basename "$POST_REMOVE_STORAGE_HOOK"))"
  NODE="$NODE" "$POST_REMOVE_STORAGE_HOOK" || die "the storage layer still lists ${NODE}. Fix it and re-run."
}

# 03c rewrites the endpoints only when it runs. Until then a talosctl call could still pick the removed IP.
drop_talos_endpoint() {
  [ "$ROLE" = controlplane ] || return 0
  talosctl config endpoint "${REMAINING_CP[@]}" > /dev/null
  talosctl config node "${REMAINING_CP[0]}" > /dev/null
  ok "talosconfig endpoints: ${REMAINING_CP[*]}"
}

print_next_steps() {
  cat << NEXT

${NODE} is in maintenance mode at ${IP}. Left for you:
  - edit its entry in inventory.yaml. Delete it to retire the machine.
    Or change host and role, then join it again: make add-node NODE=<new host>
NEXT
  [ "$ROLE" = controlplane ] && cat << NEXT
  - after the inventory edit, drop ${IP} from the apiserver certificate SANs: make reapply-talos-config
NEXT
}

# ---- main ----

parse_args "$@"
require kubectl docker
use_kubeconfig
assert_api

resolve_node
pick_survivor
probe_node_state
guard_etcd_quorum

if [ "$NODE_STATE" = running ]; then
  confirm_removal
  say "checking that replicated stores are healthy and in sync"
  wait_replication_healthy "$NODE"
  evacuate_node "$NODE"
  wait_replication_healthy "$NODE"
  move_storage_off
  wait_replication_healthy "$NODE"
  say "draining ${NODE}"
  drain_node "$NODE"
  reset_node
else
  confirm_word_always "$NODE" "${NODE} is already in maintenance mode. Delete its etcd member, Kubernetes node and storage record?" \
    || die "aborted, nothing changed"
fi

say "cleaning up the records that point at ${NODE}"
drop_etcd_member
delete_k8s_node
forget_storage_node
drop_talos_endpoint
print_next_steps
