#!/usr/bin/env bash
# Rolling in-place upgrade of the running Talos OS, one node at a time. Kubernetes is a separate roll: 03f.
# Re-run-safe: a node already on the target image is a clean no-op, so a re-run resumes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
HEALTH_TIMEOUT=1800   # secs per node for reboot + installer pull + rejoin; nodes pull over your home link
REPLICATION_HEALTH_TIMEOUT=1800  # secs to wait for PRE_DRAIN_HEALTH_HOOK before draining each node
GRACEFUL_DRAIN_TIMEOUT=600  # secs of polite drain (honors eviction) before escalating to force
FORCE_GRACE=20              # secs grace on the force-delete of stragglers (let them flush; 0=now)

# ---- state ----
# Workers FIRST: a worker holds no etcd, so an upgrade that wedges there costs no quorum and you find out
# before touching a member. Each node gets the installer its own hardware type is built from.
HOSTS=("${WORKER_HOSTS[@]}" "${CP_HOSTS[@]}")
DRAINING_NODE=""   # set around each drain; the EXIT trap reads it
HOOK_WARNED=0      # warn once, not once per node

# ---- functions ----

assert_cluster_reachable() {
  require docker kubectl
  docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
  [ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig, run step 03 (03c) first"
  use_kubeconfig    # native kubectl drives the drain
  assert_api
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null
  talosctl -n "${CP_IPS[0]}" version >/dev/null 2>&1 \
    || die "cluster API not reachable via ${CLUSTER_DIR}/talosconfig (is the cluster up?)"
}

# Don't strand a node cordoned OR tainted if we die mid-node. The out-of-service taint may be set by whatever
# watches for dead nodes, since a reboot looks like one (cordoned + NotReady past its grace), and a node
# keeping it accepts no pods.
arm_uncordon_trap() {
  trap '[ -n "$DRAINING_NODE" ] && { kubectl uncordon "$DRAINING_NODE"; kubectl taint node "$DRAINING_NODE" node.kubernetes.io/out-of-service-; } >/dev/null 2>&1 || true' EXIT
}

confirm_upgrade() {
  local h answer
  echo "== Talos rolling upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
  for h in "${HOSTS[@]}"; do
    printf 'Node:   %-12s %-16s %s -> %s\n' "$h" "${NODE_IP[$h]}" "${NODE_TYPE[$h]}" "$(installer_ref_for "$h")"
  done
  echo
  warn "this reboots EVERY node in turn (atomic A/B, a few min each). etcd quorum is held throughout."
  printf '>> proceed with the rolling upgrade? type yes: '
  read -r answer </dev/tty 2>/dev/null || answer=""
  [ "$answer" = "yes" ] || die "aborted"
}

# Talos nodes are addressed by IP, kubectl by name.
node_for_ip() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$1" '$2==ip{print $1; exit}'
}

# This repo cannot know what the cluster's replicated stores are, so the check is PRE_DRAIN_HEALTH_HOOK in
# .env: any command exiting 0 once everything is in sync. It gets NODE and REPLICATION_HEALTH_TIMEOUT in its
# environment. Unset gates nothing, which is fine with no replicated state and dangerous with it, so it warns
# rather than passing silently. Also waits out the PREVIOUS node's post-reboot resync.
wait_replication_healthy() {
  local node="$1" deadline
  if [ -z "$PRE_DRAIN_HEALTH_HOOK" ]; then
    if [ "$HOOK_WARNED" -eq 0 ]; then
      warn "PRE_DRAIN_HEALTH_HOOK is unset, so nothing checks replicated-store health before each reboot."
      warn "  On a cluster with replicated storage or databases, rebooting mid-rebuild can drop a last replica."
      HOOK_WARNED=1
    fi
    return 0
  fi
  [ -x "$PRE_DRAIN_HEALTH_HOOK" ] || die "PRE_DRAIN_HEALTH_HOOK is not executable: ${PRE_DRAIN_HEALTH_HOOK}"
  printf '  waiting for replicated stores healthy + in sync (%s)' "$(basename "$PRE_DRAIN_HEALTH_HOOK")"
  deadline=$(( $(date +%s) + REPLICATION_HEALTH_TIMEOUT ))
  while :; do
    NODE="$node" REPLICATION_HEALTH_TIMEOUT="$REPLICATION_HEALTH_TIMEOUT" \
      "$PRE_DRAIN_HEALTH_HOOK" >/dev/null 2>&1 && { printf ' ok\n'; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && die "replicated stores not healthy after ${REPLICATION_HEALTH_TIMEOUT}s (run ${PRE_DRAIN_HEALTH_HOOK} to see why). Fix, then re-run (idempotent, skips done nodes)."
    printf '.'; sleep 15
  done
}

# Pre-draining ourselves leaves Talos's own in-upgrade drain an empty node, so it cannot hang on a PDB or a
# slow-terminating pod. A per-node storage engine, and anything hard anti-affinity pins one per node, cannot
# relocate, so a graceful drain can only kill them; they come back after the reboot.
# Do NOT shorten GRACEFUL_DRAIN_TIMEOUT below the time a database switchover needs: an operator that moves the
# primary away first has its eviction REFUSED by its own PDB until the handover is done, so force-deleting it
# early turns a short switchover into a much longer failover.
# Moves roles that must survive off the node first: a database primary force-deleted at FORCE_GRACE can end up
# unable to pg_rewind and never rejoin, while a replica killed the same way just re-syncs. Runs ONCE and is
# never retried, unlike the health gate above: it mutates, so a poll loop would keep re-electing. Non-zero
# aborts before the cordon, so an abort here leaves the node untouched.
evacuate_node() {
  local node="$1"
  [ -n "$PRE_DRAIN_EVACUATE_HOOK" ] || return 0
  [ -x "$PRE_DRAIN_EVACUATE_HOOK" ] || die "PRE_DRAIN_EVACUATE_HOOK is not executable: ${PRE_DRAIN_EVACUATE_HOOK}"
  say "moving roles off ${node} ($(basename "$PRE_DRAIN_EVACUATE_HOOK"))"
  NODE="$node" "$PRE_DRAIN_EVACUATE_HOOK" \
    || die "could not move roles off ${node}. Nothing was drained; fix and re-run (idempotent, skips done nodes)."
}

drain_node() {
  local node="$1"
  kubectl cordon "$node" >/dev/null
  if ! kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
        --timeout="${GRACEFUL_DRAIN_TIMEOUT}s" >/dev/null 2>&1; then
    warn "graceful drain of ${node} timed out; force-deleting stragglers"
    # The selector is node-wide, so ONE wedged pod force-kills every other pod on the node too. Empty keeps
    # that; set FORCE_DELETE_SKIP to spare anything that will not come back from it.
    kubectl delete pod --all-namespaces --field-selector "spec.nodeName=${node}" \
      ${FORCE_DELETE_SKIP:+--selector "$FORCE_DELETE_SKIP"} \
      --force --grace-period="${FORCE_GRACE}" >/dev/null 2>&1 || true
  fi
}

uncordon_node() {
  kubectl uncordon "$1" >/dev/null 2>&1 || true   # Talos uncordons on rejoin; make it explicit and idempotent
  kubectl taint node "$1" node.kubernetes.io/out-of-service- >/dev/null 2>&1 || true
}

# Health is asked of a CONTROL-PLANE node, never of the node just upgraded: Talos answers this check only
# there, so aiming it at a worker always fails. A false negative just stops us early; re-running resumes.
upgrade_host() {
  local host="$1" ip installer node
  ip="${NODE_IP[$host]}"
  installer="$(installer_ref_for "$host")"
  node="$(node_for_ip "$ip")"
  [ -n "$node" ] || die "no k8s node has InternalIP ${ip} (is the cluster up / is inventory.yaml right?)"

  # Gated before cordoning, so an abort here leaves no stray cordon.
  say "checking replicated stores are healthy + in sync before draining ${node} (${ip})"
  wait_replication_healthy "$node"

  # Healthy FIRST, then move roles: a switchover into a cluster that is still rebuilding picks a replica that
  # is not caught up. The second gate then covers the switchover's own resync before anything is drained.
  evacuate_node "$node"
  wait_replication_healthy "$node"

  say "draining ${node}"
  DRAINING_NODE="$node"
  drain_node "$node"

  say "upgrading ${ip} -> ${installer}"
  # --wait tracks the node until it reboots into the new system and rejoins; a node already on the target
  # image completes immediately. talosctl won't proceed if the reboot would cost etcd quorum.
  if talosctl -n "$ip" upgrade --image "$installer" --wait --timeout "${HEALTH_TIMEOUT}s"; then
    ok "${ip} upgraded"
  else
    die "${ip} upgrade failed (see above). Cluster left as-is; fix and re-run (idempotent, skips done nodes)."
  fi

  say "waiting for cluster health before the next node"
  talosctl -n "${CP_IPS[0]}" health --wait-timeout "${HEALTH_TIMEOUT}s" >/dev/null 2>&1 \
    || die "cluster not healthy after upgrading ${ip}; stopping. Investigate, then re-run to resume."

  uncordon_node "$node"
  DRAINING_NODE=""
}

rebalance_workloads() {
  bash "${SCRIPT_DIR}/03g_rebalance_workloads.sh" \
    || warn "rebalance had failures (the upgrade itself succeeded); re-run: make rebalance-workloads"
}

print_result() {
  local h
  say "ROLLING UPGRADE COMPLETE"
  for h in "${HOSTS[@]}"; do
    printf '   image:  %-12s %s\n' "$h" "$(installer_ref_for "$h")"
  done
  echo "   verify: talosctl version   (server tag on every node)   /   kubectl get nodes"
  echo "   note:   this did NOT change the k8s version; for that run 03f_k8s_upgrade.sh"
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
