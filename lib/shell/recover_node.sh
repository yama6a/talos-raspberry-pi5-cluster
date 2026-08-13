#!/usr/bin/env bash
# Puts ONE replaced or wiped node back into a running cluster, and fixes the machine-level state that does not
# fix itself: its stale etcd member, its machine config, its kubelet registration.
# The executable half of docs/05_node_recovery.md. The workloads need nothing: their volumes belong to the
# storage layer, not to the node, so they moved to a survivor on their own long before this runs.
#
# It stops at a Ready node. A storage layer that keeps its own per-node records (a disk UUID, say) may still
# need reconciling afterwards, which is the platform's job, not this repo's.
#
# Re-run it as often as you like. Every step re-checks before acting, so a partial failure is recovered by
# running it again, which is the normal way to get past a step that needed more time.
#
# Usage:
#   bash recover_node.sh <hostname> [--yes]
#   make recover-node NODE=talos-cp3
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
MAINT_WAIT=600      # secs to wait for the node to answer in maintenance mode before giving up
READY_WAIT=900      # secs to wait for the kubelet to register and report Ready after the config apply
SETTLE_WAIT=300     # secs to wait for the cluster to converge once the node is back
POLL=10

NODE=""; ASSUME_YES="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|--apply) ASSUME_YES="true"; shift ;;
    -*)            die "unknown flag: $1 (see the usage header)" ;;
    *)             NODE="$1"; shift ;;
  esac
done

require kubectl docker
use_kubeconfig
assert_api

[ -n "$NODE" ] || { printf '  %s\n' "${ALL_HOSTS[@]}"; read -rp "Node to recover: " NODE; }

IP="${NODE_IP[$NODE]:-}"
[ -n "$IP" ] || die "unknown node '${NODE}': inventory.yaml has ${ALL_HOSTS[*]}"
ROLE="${NODE_ROLE[$NODE]}"

# Peers are always control-plane: every etcd call below needs a node that holds the cluster, and a worker
# holds none. Recovering a worker still talks to one of these.
PEERS=(); PEER_IPS=()
for h in "${CP_HOSTS[@]}"; do
  [ "$h" = "$NODE" ] && continue
  PEERS+=("$h"); PEER_IPS+=("${NODE_IP[$h]}")
done
[ "${#PEERS[@]}" -ge 1 ] || die "no surviving control-plane node to talk to; this script rejoins a node to a cluster that is still up"

say "recovering ${NODE} (${IP}, ${ROLE});  survivors: ${PEERS[*]}"

# --- 1. preflight: the survivors have to be able to carry the cluster and rebuild from ------------------
say "1/5 preflight"

SURVIVOR=""   # the healthy node every etcd call below is aimed at
for i in "${!PEERS[@]}"; do
  if [ "$(kubectl get node "${PEERS[$i]}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)" = "True" ]; then
    SURVIVOR="${PEERS[$i]}"; SURVIVOR_IP="${PEER_IPS[$i]}"; break
  fi
done
[ -n "$SURVIVOR" ] || die "no surviving node is Ready; recovering one node needs the rest of the cluster up"
ok "talking to ${SURVIVOR} (${SURVIVOR_IP})"


echo
echo "    About to, on ${NODE}: apply its machine config and rejoin it to the cluster."
[ "$ROLE" = controlplane ] && echo "    Also drop its stale etcd member, because it is a control-plane node."
echo "    Its data is already gone; this deletes the API objects that still point at it."
echo
confirm "Proceed?" || { warn "nothing changed"; exit 0; }

# Probed ONCE, before anything acts on it. A maintenance node answers --insecure and rejects a secure call; a
# configured one is the reverse. Every step below branches on this rather than re-probing, so a re-run against
# a node that has already come back cannot mistake it for one that is still down.
ADOPTED="no"
talosctl -n "$IP" -e "$IP" version >/dev/null 2>&1 && ADOPTED="yes"

# --- 2. etcd: drop the member whose peer URL is this node -----------------------------------------------
# A wiped node comes back with a NEW etcd identity, and the old entry at the same peer URL blocks the join.
say "2/5 etcd membership"
if [ "$ROLE" = worker ]; then
  ok "${NODE} is a worker, so it runs no etcd and there is no member to drop"
else
  MEMBER="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2>/dev/null | awk -v ip="$IP" '$0 ~ ip {print $2}' | head -1)"
  if [ -z "$MEMBER" ]; then
    ok "no etcd member at ${IP} (already removed, or the node never joined)"
  elif [ "$ADOPTED" = "yes" ]; then
    # The member belongs to a node that is UP and holding our config, so it is the real one, not a leftover.
    # Removing it would evict a working control-plane node and leave its etcd restarting forever.
    ok "${NODE} is already back and holds etcd member ${MEMBER}; leaving it alone"
  elif talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd remove-member "$MEMBER" >/dev/null 2>&1; then
    ok "removed stale etcd member ${MEMBER}"
  else
    bad "could not remove etcd member ${MEMBER}; check quorum on ${SURVIVOR}"
  fi
fi

# --- 3. machine config ---------------------------------------------------------------------------------
say "3/5 machine config"
if [ "$ADOPTED" = "yes" ]; then
  ok "${IP} already answers securely, so it holds our config; not re-applying"
else
  printf '    waiting for %s in maintenance mode (up to %ss) ' "$IP" "$MAINT_WAIT"
  if ! wait_talos_api "$IP" "$MAINT_WAIT" insecure; then
    echo " TIMEOUT"
    bad "${IP} is neither configured nor in maintenance"
    warn "is it powered on and on the network?  arp -n ${IP}  &&  nc -vz ${IP} ${API_PORT}"
    warn "if it has not been wiped yet, do that first: make flash-talos-nvme, or talosctl reset"
    summary; exit 1
  fi
  echo "ready"
  # 03c with a hostname applies to that node alone and skips the bootstrap, while still building certSANs and
  # the talosconfig endpoints from the full list.
  if bash "${SCRIPT_DIR}/03c_talos_cluster_config.sh" "$NODE"; then
    ok "applied ${NODE}'s machine config"
  else
    bad "03c failed for ${NODE}"; summary; exit 1
  fi
fi

# --- 4. kubelet ----------------------------------------------------------------------------------------
say "4/5 kubernetes node"
printf '    waiting for %s Ready (up to %ss) ' "$NODE" "$READY_WAIT"
deadline=$(( $(date +%s) + READY_WAIT ))
until [ "$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)" = "True" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo " TIMEOUT"
    bad "${NODE} did not reach Ready"
    warn "if the node object is stuck on a stale identity: kubectl delete node ${NODE}, the kubelet re-registers"
    summary; exit 1
  fi
  printf '.'; sleep "$POLL"
done
echo "ready"
ok "${NODE} is Ready"
if [ "$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')" = "true" ]; then
  kubectl uncordon "$NODE" >/dev/null 2>&1 && ok "uncordoned ${NODE}" || bad "could not uncordon ${NODE}"
fi
# Whatever set the out-of-service taint may clear it once the node is Ready, but a node that keeps it accepts
# no pods, so don't make the convergence wait below depend on anything else running.
kubectl taint node "$NODE" node.kubernetes.io/out-of-service- >/dev/null 2>&1 \
  && ok "removed the out-of-service taint from ${NODE}"



# --- 5. converge ---------------------------------------------------------------------------------------
# Counts LIVE pods only. A pod whose node died is left behind in phase Failed and never becomes Running, so
# counting those means waiting for something that cannot happen. They are reported once, at the end, as cruft.
say "5/5 waiting for things to come back (up to ${SETTLE_WAIT}s)"
deadline=$(( $(date +%s) + SETTLE_WAIT ))
while :; do
  PENDING="$(kubectl get pods -A --field-selector=status.phase!=Failed --no-headers 2>/dev/null | grep -Evc 'Running|Completed')"
  printf '    pods not running: %s\n' "${PENDING:-?}"
  [ "${PENDING:-1}" -eq 0 ] && break
  [ "$(date +%s)" -ge "$deadline" ] && { warn "not fully converged yet; a storage rebuild or a database clone can outlast this"; break; }
  sleep "$POLL"
done

MCOUNT="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2>/dev/null | grep -c '^' )"
[ "${MCOUNT:-0}" -gt 1 ] && ok "etcd has $(( MCOUNT - 1 )) members"

# Pods their node died under. Harmless, but they show up in every `get pods` from here on.
ORPHANS="$(kubectl get pods -A --field-selector=status.phase=Failed -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . )"

cat <<NEXT

Left for you:
  - reconcile whatever per-node records your storage layer keeps. A reflashed node comes back with a fresh
    filesystem, and a driver that stamped the old one will refuse the disk until told otherwise.
  - re-spread the stateless Deployments once everything is healthy: make rebalance-workloads
NEXT
[ "${ORPHANS:-0}" -gt 0 ] && cat <<NEXT
  - ${ORPHANS} pod(s) left in phase Failed by the outage, which nothing garbage-collects:
      kubectl delete pods -A --field-selector=status.phase=Failed
NEXT
cat <<NEXT

Then walk docs/05_node_recovery.md's verification step to confirm.
NEXT

summary || exit 1
