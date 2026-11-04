#!/usr/bin/env bash
# Rolling upgrade of the Talos OS, one node at a time. Kubernetes is 03f. Takes optional hostnames to upgrade
# only those, which is how a stopped run resumes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
HEALTH_TIMEOUT=1800 # secs per node for reboot, installer pull and rejoin, over your home link
# Longhorn waits 30 min (replica-replenishment-wait-interval) before it rebuilds a replica the last reboot lost,
# then copies it. A 100Gi volume needs about 50 min in all.
REPLICATION_HEALTH_TIMEOUT=3600 # secs to wait for PRE_DRAIN_HEALTH_HOOK before draining each node
# Keep GRACEFUL_DRAIN_TIMEOUT above a database switchover: its PDB refuses the eviction until the handover ends.
GRACEFUL_DRAIN_TIMEOUT=600 # secs of graceful drain before the force-delete
FORCE_GRACE=20             # secs of grace on the force-delete, so stragglers can flush. 0 kills at once

# ---- state ----
# Workers first: a worker holds no etcd, so a failed upgrade there costs no quorum.
HOSTS=("${WORKER_HOSTS[@]}" "${CP_HOSTS[@]}")
DRAINING_NODE="" # the EXIT trap reads it
HOOK_WARNED=0

# ---- functions ----

# Each node gets a primary switchover and a drain before talosctl sees it, so a node already done must be left
# out by name. A node reports its Talos version but not the build revision, so the script cannot tell on its own.
select_hosts() {
  local h all
  [ $# -gt 0 ] || return 0
  for h in "$@"; do
    [ -n "${NODE_ROLE[$h]:-}" ] || die "unknown node '${h}': inventory.yaml has ${ALL_HOSTS[*]}"
  done
  all=("${HOSTS[@]}")
  HOSTS=()
  for h in "${all[@]}"; do
    if [[ " $* " == *" ${h} "* ]]; then HOSTS+=("$h"); fi
  done
}

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
  trap '[ -n "$DRAINING_NODE" ] && uncordon_node "$DRAINING_NODE"' EXIT
}

confirm_upgrade() {
  local h answer
  echo "== Talos rolling upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
  for h in "${HOSTS[@]}"; do
    printf 'Node:   %-12s %-16s %-16s %s\n' "$h" "${NODE_IP[$h]}" "${NODE_TYPE[$h]}" "$(installer_ref_for "$h")"
  done
  echo
  warn "this reboots each node above in turn, a few minutes each. etcd keeps quorum throughout."
  printf '>> proceed with the rolling upgrade? Type yes: '
  read -r answer < /dev/tty 2> /dev/null || answer=""
  [ "$answer" = "yes" ] || die "aborted"
}

# Talos nodes are addressed by IP, kubectl by name.
node_for_ip() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$1" '$2==ip{print $1; exit}'
}

uncordon_node() {
  kubectl uncordon "$1" > /dev/null 2>&1 || true # talosctl upgrade also uncordons
  kubectl taint node "$1" node.kubernetes.io/out-of-service- > /dev/null 2>&1 || true
}

# Health is asked of a control-plane node, because Talos answers it only there.
# $2 and $3 are the nodes still to do, with and without this one, for the resume hint.
upgrade_host() {
  local host="$1" from_here="$2" after_here="$3" ip installer node resume
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
  # talosctl refuses a reboot that would cost etcd quorum. It reinstalls and reboots even on the same image.
  if talosctl -n "$ip" upgrade --image "$installer" --wait --timeout "${HEALTH_TIMEOUT}s"; then
    ok "${ip} upgraded"
  else
    die "${ip} upgrade failed, see above. The cluster is left as it is. Fix it, then resume: make upgrade-talos NODES=\"${from_here}\""
  fi

  say "waiting for cluster health before the next node"
  resume="Nothing is left to upgrade."
  [ -n "$after_here" ] && resume="Then resume: make upgrade-talos NODES=\"${after_here}\""
  talosctl health -n "${CP_IPS[0]}" --wait-timeout "${HEALTH_TIMEOUT}s" > /dev/null 2>&1 \
    || die "cluster not healthy after upgrading ${ip}. Stopping. Investigate. ${resume}"

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

select_hosts "$@"
assert_cluster_reachable
arm_uncordon_trap
confirm_upgrade

for i in "${!HOSTS[@]}"; do
  upgrade_host "${HOSTS[$i]}" "${HOSTS[*]:i}" "${HOSTS[*]:i+1}"
done

rebalance_workloads
print_result
