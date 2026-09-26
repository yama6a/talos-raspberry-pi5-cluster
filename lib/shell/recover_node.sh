#!/usr/bin/env bash
# Puts one replaced or wiped node back into a running cluster: etcd member, machine config, kubelet.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
recover_node.sh <host> [--yes]             (or: make recover-node NODE=<host> [YES=1])
  <host>   the node to rejoin. Omit it to pick from the inventory
  --yes    skip the confirmation prompt

Safe to re-run: every step checks before it acts, so running it again is how you get past a step that needed
more time. It stops at a Ready node. A storage layer that keeps per-node records needs its own step after this.
EOF
}

# ---- knobs ----
MAINT_WAIT=600  # secs to wait for the node to answer in maintenance mode
READY_WAIT=900  # secs to wait for the kubelet to report Ready after the config apply
SETTLE_WAIT=300 # secs to wait for the cluster to converge once the node is back
POLL=10

# ---- state ----
NODE=""            # set by parse_args
ASSUME_YES="false" # only --yes skips the prompt here, never an inherited ASSUME_YES
IP=""              # set by resolve_node
ROLE=""
PEERS=()
PEER_IPS=()
SURVIVOR="" # the healthy node every etcd call goes to
SURVIVOR_IP=""
ADOPTED="no" # set by probe_node_state
ORPHANS=0    # set by wait_for_convergence

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --yes | --apply)
        ASSUME_YES="true"
        shift
        ;;
      -*) die "unknown flag: $1 (see --help)" ;;
      *)
        NODE="$1"
        shift
        ;;
    esac
  done
}

# Peers are control-plane nodes, because every etcd call needs one, even when the lost node is a worker.
resolve_node() {
  local h
  [ -n "$NODE" ] || {
    printf '  %s\n' "${ALL_HOSTS[@]}"
    read -rp "Node to recover: " NODE
  }
  IP="${NODE_IP[$NODE]:-}"
  [ -n "$IP" ] || die "unknown node '${NODE}': inventory.yaml has ${ALL_HOSTS[*]}"
  ROLE="${NODE_ROLE[$NODE]}"
  for h in "${CP_HOSTS[@]}"; do
    [ "$h" = "$NODE" ] && continue
    PEERS+=("$h")
    PEER_IPS+=("${NODE_IP[$h]}")
  done
  [ "${#PEERS[@]}" -ge 1 ] || die "no surviving control-plane node to talk to. This script needs a cluster that is still up"
  say "recovering ${NODE} (${IP}, ${ROLE}). Survivors: ${PEERS[*]}"
}

pick_survivor() {
  local i
  say "1/5 preflight"
  for i in "${!PEERS[@]}"; do
    if [ "$(kubectl get node "${PEERS[$i]}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2> /dev/null)" = "True" ]; then
      SURVIVOR="${PEERS[$i]}"
      SURVIVOR_IP="${PEER_IPS[$i]}"
      break
    fi
  done
  [ -n "$SURVIVOR" ] || die "no surviving node is Ready. Recovering one node needs the rest of the cluster up"
  ok "talking to ${SURVIVOR} (${SURVIVOR_IP})"
}

confirm_recovery() {
  echo
  echo "    About to, on ${NODE}: apply its machine config and rejoin it to the cluster."
  [ "$ROLE" = controlplane ] && echo "    Also drop its stale etcd member, because it is a control-plane node."
  echo "    Its data is already gone. This deletes the API objects that still point at it."
  echo
  confirm "Proceed?" || {
    warn "nothing changed"
    exit 0
  }
}

# Probed once, before anything acts. Every step below reads this, so a re-run against a node that is already
# back cannot mistake it for one that is still down.
probe_node_state() {
  talosctl -n "$IP" -e "$IP" version > /dev/null 2>&1 && ADOPTED="yes"
  return 0
}

# A wiped node comes back with a new etcd identity, and the old member at the same peer URL blocks the join.
drop_stale_etcd_member() {
  local member
  say "2/5 etcd membership"
  if [ "$ROLE" = worker ]; then
    ok "${NODE} is a worker, so it runs no etcd and there is no member to drop"
    return 0
  fi
  member="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2> /dev/null | awk -v ip="$IP" '$0 ~ ip {print $2}' | head -1)"
  if [ -z "$member" ]; then
    ok "no etcd member at ${IP}. Already removed, or the node never joined"
  elif [ "$ADOPTED" = "yes" ]; then
    # The node is up with our config, so this member is live. Removing it would leave its etcd restarting forever.
    ok "${NODE} is already back and holds etcd member ${member}. Leaving it alone"
  elif talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd remove-member "$member" > /dev/null 2>&1; then
    ok "removed stale etcd member ${member}"
  else
    bad "could not remove etcd member ${member}. Check quorum on ${SURVIVOR}"
  fi
}

# 03c with a hostname applies to that node alone and skips the bootstrap.
apply_machine_config() {
  say "3/5 machine config"
  if [ "$ADOPTED" = "yes" ]; then
    ok "${IP} already answers securely, so it holds our config. Not applying again"
    return 0
  fi
  printf '    waiting for %s in maintenance mode (up to %ss) ' "$IP" "$MAINT_WAIT"
  if ! wait_talos_api "$IP" "$MAINT_WAIT" insecure; then
    echo " timed out"
    bad "${IP} is neither configured nor in maintenance mode"
    warn "is it powered on and on the network?  arp -n ${IP}  &&  nc -vz ${IP} ${API_PORT}"
    warn "if it is not wiped yet, do that first: make flash-talos-nvme, or talosctl reset"
    summary
    exit 1
  fi
  echo "ready"
  if bash "${SCRIPT_DIR}/03c_talos_cluster_config.sh" "$NODE"; then
    ok "applied ${NODE}'s machine config"
  else
    bad "03c failed for ${NODE}"
    summary
    exit 1
  fi
}

# A node that keeps the out-of-service taint accepts no pods, and whatever set it may no longer run.
wait_for_node_ready() {
  local deadline
  say "4/5 kubernetes node"
  printf '    waiting for %s Ready (up to %ss) ' "$NODE" "$READY_WAIT"
  deadline=$(($(date +%s) + READY_WAIT))
  until [ "$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2> /dev/null)" = "True" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo " timed out"
      bad "${NODE} did not reach Ready"
      warn "if the node object is stuck on a stale identity, run kubectl delete node ${NODE}. The kubelet registers again"
      summary
      exit 1
    fi
    printf '.'
    sleep "$POLL"
  done
  echo "ready"
  ok "${NODE} is Ready"
  if [ "$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')" = "true" ]; then
    kubectl uncordon "$NODE" > /dev/null 2>&1 && ok "uncordoned ${NODE}" || bad "could not uncordon ${NODE}"
  fi
  kubectl taint node "$NODE" node.kubernetes.io/out-of-service- > /dev/null 2>&1 \
    && ok "removed the out-of-service taint from ${NODE}"
  return 0
}

# Counts live pods only. A pod left in phase Failed never runs again, so it is reported at the end instead.
wait_for_convergence() {
  local deadline pending mcount
  say "5/5 waiting for things to come back (up to ${SETTLE_WAIT}s)"
  deadline=$(($(date +%s) + SETTLE_WAIT))
  while :; do
    pending="$(kubectl get pods -A --field-selector=status.phase!=Failed --no-headers 2> /dev/null | grep -Evc 'Running|Completed')"
    printf '    pods not running: %s\n' "${pending:-?}"
    [ "${pending:-1}" -eq 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && {
      warn "not fully converged yet. A storage rebuild or a database clone can take longer than this wait"
      break
    }
    sleep "$POLL"
  done
  mcount="$(talosctl -n "$SURVIVOR_IP" -e "$SURVIVOR_IP" etcd members 2> /dev/null | grep -c '^')"
  [ "${mcount:-0}" -gt 1 ] && ok "etcd has $((mcount - 1)) members"
  ORPHANS="$(kubectl get pods -A --field-selector=status.phase=Failed -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2> /dev/null | grep -c .)"
  return 0
}

print_next_steps() {
  cat << NEXT

Left for you:
  - reconcile any per-node records your storage layer keeps. A reflashed node has a fresh filesystem, and a
    driver that stamped the old one refuses the disk until told otherwise.
  - re-spread the stateless Deployments once everything is healthy: make rebalance-workloads
NEXT
  [ "${ORPHANS:-0}" -gt 0 ] && cat << NEXT
  - ${ORPHANS} pod(s) left in phase Failed by the outage, which nothing garbage-collects:
      kubectl delete pods -A --field-selector=status.phase=Failed
NEXT
  cat << NEXT

Then run the verify step in docs/runbooks/05_node_recovery.md.
NEXT
}

# ---- main ----

parse_args "$@"
require kubectl docker
use_kubeconfig
assert_api

resolve_node
pick_survivor
confirm_recovery
probe_node_state

drop_stale_etcd_member
apply_machine_config
wait_for_node_ready
wait_for_convergence
print_next_steps

summary || exit 1
