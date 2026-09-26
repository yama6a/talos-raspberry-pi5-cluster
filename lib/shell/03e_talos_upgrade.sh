#!/usr/bin/env bash
# Rolling upgrade of the Talos OS, one node at a time. Kubernetes is 03f. A re-run skips nodes already done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
HEALTH_TIMEOUT=1800             # secs per node for reboot, installer pull and rejoin, over your home link
REPLICATION_HEALTH_TIMEOUT=1800 # secs to wait for PRE_DRAIN_HEALTH_HOOK before draining each node
# Keep GRACEFUL_DRAIN_TIMEOUT above a database switchover: its PDB refuses the eviction until the handover ends.
GRACEFUL_DRAIN_TIMEOUT=600 # secs of graceful drain before the force-delete
FORCE_GRACE=20             # secs of grace on the force-delete, so stragglers can flush. 0 kills at once

# ---- state ----
# Workers first: a worker holds no etcd, so a failed upgrade there costs no quorum.
HOSTS=("${WORKER_HOSTS[@]}" "${CP_HOSTS[@]}")
DRAINING_NODE="" # the EXIT trap reads it
HOOK_WARNED=0

# ---- functions ----

assert_cluster_reachable() {
  require docker kubectl
  docker info > /dev/null 2>&1 || die "docker not responding. Start Rancher or Docker Desktop"
  [ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig. Run 03c first"
  use_kubeconfig # native kubectl drives the drain
  assert_api
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" > /dev/null
  talosctl -n "${CP_IPS[0]}" version > /dev/null 2>&1 \
    || die "cluster API not reachable through ${CLUSTER_DIR}/talosconfig. Is the cluster up?"
}

# Never leave a node cordoned or tainted after a failure. A dead-node watcher may set the out-of-service taint
# during the reboot, and a node that keeps it accepts no pods.
arm_uncordon_trap() {
  trap '[ -n "$DRAINING_NODE" ] && { kubectl uncordon "$DRAINING_NODE"; kubectl taint node "$DRAINING_NODE" node.kubernetes.io/out-of-service-; } >/dev/null 2>&1 || true' EXIT
}

confirm_upgrade() {
  local h answer
  echo "== Talos rolling upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
  for h in "${HOSTS[@]}"; do
    printf 'Node:   %-12s %-16s %-16s %s\n' "$h" "${NODE_IP[$h]}" "${NODE_TYPE[$h]}" "$(installer_ref_for "$h")"
  done
  echo
  warn "this reboots every node in turn, a few minutes each. etcd keeps quorum throughout."
  printf '>> proceed with the rolling upgrade? Type yes: '
  read -r answer < /dev/tty 2> /dev/null || answer=""
  [ "$answer" = "yes" ] || die "aborted"
}

# Talos nodes are addressed by IP, kubectl by name.
node_for_ip() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$1" '$2==ip{print $1; exit}'
}

# PRE_DRAIN_HEALTH_HOOK exits 0 once every replicated store is in sync. It gets NODE and
# REPLICATION_HEALTH_TIMEOUT. This also waits out the previous node's resync.
wait_replication_healthy() {
  local node="$1" deadline
  if [ -z "$PRE_DRAIN_HEALTH_HOOK" ]; then
    if [ "$HOOK_WARNED" -eq 0 ]; then
      warn "PRE_DRAIN_HEALTH_HOOK is unset, so nothing checks replicated stores before each reboot."
      warn "  With replicated storage or databases, a reboot during a rebuild can drop the last replica."
      HOOK_WARNED=1
    fi
    return 0
  fi
  [ -x "$PRE_DRAIN_HEALTH_HOOK" ] || die "PRE_DRAIN_HEALTH_HOOK is not executable: ${PRE_DRAIN_HEALTH_HOOK}"
  printf '  waiting for replicated stores to be healthy and in sync (%s)' "$(basename "$PRE_DRAIN_HEALTH_HOOK")"
  deadline=$(($(date +%s) + REPLICATION_HEALTH_TIMEOUT))
  while :; do
    NODE="$node" REPLICATION_HEALTH_TIMEOUT="$REPLICATION_HEALTH_TIMEOUT" \
      "$PRE_DRAIN_HEALTH_HOOK" > /dev/null 2>&1 && {
      printf ' ok\n'
      return 0
    }
    [ "$(date +%s)" -ge "$deadline" ] && die "replicated stores not healthy after ${REPLICATION_HEALTH_TIMEOUT}s. Run ${PRE_DRAIN_HEALTH_HOOK} to see why, fix it, then re-run. Done nodes are skipped."
    printf '.'
    sleep 15
  done
}

# A force-deleted database primary may never rejoin, while a replica just re-syncs, so roles move off first.
# Runs once, never polled, because it changes state. A failure stops before the cordon.
evacuate_node() {
  local node="$1"
  [ -n "$PRE_DRAIN_EVACUATE_HOOK" ] || return 0
  [ -x "$PRE_DRAIN_EVACUATE_HOOK" ] || die "PRE_DRAIN_EVACUATE_HOOK is not executable: ${PRE_DRAIN_EVACUATE_HOOK}"
  say "moving roles off ${node} ($(basename "$PRE_DRAIN_EVACUATE_HOOK"))"
  NODE="$node" "$PRE_DRAIN_EVACUATE_HOOK" \
    || die "could not move roles off ${node}. Nothing was drained. Fix it and re-run, done nodes are skipped."
}

drain_node() {
  local node="$1"
  kubectl cordon "$node" > /dev/null
  if ! kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
    --timeout="${GRACEFUL_DRAIN_TIMEOUT}s" > /dev/null 2>&1; then
    warn "graceful drain of ${node} timed out. Force-deleting the rest"
    # Node-wide, so one stuck pod force-kills every other pod here too. FORCE_DELETE_SKIP spares the fragile ones.
    kubectl delete pod --all-namespaces --field-selector "spec.nodeName=${node}" \
      ${FORCE_DELETE_SKIP:+--selector "$FORCE_DELETE_SKIP"} \
      --force --grace-period="${FORCE_GRACE}" > /dev/null 2>&1 || true
  fi
}

uncordon_node() {
  kubectl uncordon "$1" > /dev/null 2>&1 || true # Talos also uncordons on rejoin
  kubectl taint node "$1" node.kubernetes.io/out-of-service- > /dev/null 2>&1 || true
}

# Health is asked of a control-plane node, because Talos answers it only there.
upgrade_host() {
  local host="$1" ip installer node
  ip="${NODE_IP[$host]}"
  installer="$(installer_ref_for "$host")"
  node="$(node_for_ip "$ip")"
  [ -n "$node" ] || die "no Kubernetes node has InternalIP ${ip}. Is the cluster up, and is inventory.yaml right?"

  # Before the cordon, so an abort here leaves no stray cordon.
  say "checking that replicated stores are healthy and in sync before draining ${node} (${ip})"
  wait_replication_healthy "$node"

  # Healthy before a switchover, which would otherwise pick a replica that is behind. Then again after it.
  evacuate_node "$node"
  wait_replication_healthy "$node"

  say "draining ${node}"
  DRAINING_NODE="$node"
  drain_node "$node"

  say "upgrading ${ip} to ${installer}"
  # talosctl refuses a reboot that would cost etcd quorum. A node already on the target image returns at once.
  if talosctl -n "$ip" upgrade --image "$installer" --wait --timeout "${HEALTH_TIMEOUT}s"; then
    ok "${ip} upgraded"
  else
    die "${ip} upgrade failed, see above. The cluster is left as it is. Fix it and re-run, done nodes are skipped."
  fi

  say "waiting for cluster health before the next node"
  talosctl -n "${CP_IPS[0]}" health --wait-timeout "${HEALTH_TIMEOUT}s" > /dev/null 2>&1 \
    || die "cluster not healthy after upgrading ${ip}. Stopping. Investigate, then re-run to resume."

  uncordon_node "$node"
  DRAINING_NODE=""
}

rebalance_workloads() {
  bash "${SCRIPT_DIR}/03g_rebalance_workloads.sh" \
    || warn "the rebalance had failures, but the upgrade succeeded. Re-run: make rebalance-workloads"
}

print_result() {
  local h
  say "rolling upgrade complete"
  for h in "${HOSTS[@]}"; do
    printf '   image:  %-12s %s\n' "$h" "$(installer_ref_for "$h")"
  done
  echo "   check:  make talosctl -- version   (server tag on every node)   and   kubectl get nodes"
  echo "   note:   the Kubernetes version is unchanged. For that, run make upgrade-k8s"
}

# ---- main ----

assert_cluster_reachable
arm_uncordon_trap
confirm_upgrade

for host in "${HOSTS[@]}"; do
  upgrade_host "$host"
done

rebalance_workloads
print_result
