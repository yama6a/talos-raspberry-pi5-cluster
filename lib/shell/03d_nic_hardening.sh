#!/usr/bin/env bash
# Applies nic-keeper, the runtime half of the Pi 5 `macb` NIC fix (siderolabs/sbc-raspberrypi #91), and checks
# that the machine-config half from 03c is in effect.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
HW_TYPE="rpi5"                                                 # the macb wedge is Pi 5-only
OUTDIR="${CLUSTER_DIR}"                                        # talosctl() mounts it as /work
KUBECTL_IMAGE="registry.k8s.io/kubectl:v${KUBERNETES_VERSION}" # matches the cluster version. The tag needs the v
NIC_KEEPER_NS="kube-system"                                    # Talos exempts kube-system from Pod Security
NIC_KEEPER_NAME="nic-keeper"                                   # ConfigMap + DaemonSet share the name
NIC_KEEPER_MANIFEST="${REPO_ROOT}/lib/k8s/nic-keeper.yaml"
ROLLOUT_TIMEOUT=300 # secs to wait for the DaemonSet to roll after a loop-script change

# ---- state ----
NODES_ARR=() # set by select_target_nodes

# ---- functions ----

# Dockerized and matched to the cluster version. Shadows any host kubectl on purpose, so none is needed.
kubectl() { docker run --rm -i --network host -v "${OUTDIR}:/work" \
  -e KUBECONFIG=/work/kubeconfig "${KUBECTL_IMAGE}" "$@"; }

# Parsers over a `get ethernetstatus -o yaml` blob.
eth_status() { talosctl -n "$1" get ethernetstatus "$IFACE" -o yaml 2> /dev/null; }
ring_cur() { awk -v k="$2:" '/^    rings:/{r=1} r&&$1==k{print $2;exit}' <<< "$1"; } # $1=blob $2=rx|tx
feat_val() { awk -v k="$2:" '$1==k{print $2;exit}' <<< "$1"; }                       # on|off

check_prerequisites() {
  say "checking prerequisites"
  require docker
  docker info > /dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
  [ -f "${OUTDIR}/talosconfig" ] || die "missing ${OUTDIR}/talosconfig, run 03c first"
  [ -f "${OUTDIR}/kubeconfig" ] || die "missing ${OUTDIR}/kubeconfig, run 03c first"
}

# Pi 5 nodes from the inventory, not the talosconfig endpoints. Those are control-plane only, so they would
# miss a Pi worker and include a node with another NIC.
select_target_nodes() {
  local h
  for h in "${ALL_HOSTS[@]}"; do [ "${NODE_TYPE[$h]}" = "$HW_TYPE" ] && NODES_ARR+=("${NODE_IP[$h]}"); done
  [ "${#NODES_ARR[@]}" -gt 0 ] || die "no node in inventory.yaml has type ${HW_TYPE}, so there is no macb NIC to harden"
  echo "   nodes: ${NODES_ARR[*]}"
}

verify_ethernet_config() {
  local ip st done_ok k
  say "verify, the EthernetConfig from 03c is in effect (EthernetStatus) on every node"
  for ip in "${NODES_ARR[@]}"; do
    st=""
    for _ in $( # up to about 150s, because the EthernetSpec controller backs off after errors
      seq 1 30
    ); do
      st="$(eth_status "$ip")"
      done_ok=1
      [ "$(ring_cur "$st" rx)" = "$RPI5_RINGS_RX" ] || done_ok=0
      [ "$(ring_cur "$st" tx)" = "$RPI5_RINGS_TX" ] || done_ok=0
      for k in "${RPI5_OFFLOADS_OFF[@]}"; do [ "$(feat_val "$st" "$k")" = off ] || done_ok=0; done
      [ "$done_ok" = 1 ] && break
      sleep 3
    done
    for k in "${RPI5_OFFLOADS_OFF[@]}"; do
      [ "$(feat_val "$st" "$k")" = off ] && ok "${ip}: ${k} = off" || bad "${ip}: ${k} still $(feat_val "$st" "$k")"
    done
    [ "$(ring_cur "$st" rx)" = "$RPI5_RINGS_RX" ] && ok "${ip}: ring rx = ${RPI5_RINGS_RX}" \
      || bad "${ip}: ring rx = $(ring_cur "$st" rx) != ${RPI5_RINGS_RX}"
    [ "$(ring_cur "$st" tx)" = "$RPI5_RINGS_TX" ] && ok "${ip}: ring tx = ${RPI5_RINGS_TX}" \
      || bad "${ip}: ring tx = $(ring_cur "$st" tx) != ${RPI5_RINGS_TX}"
  done
}

verify_watchdog() {
  local ip ws
  say "verify, the watchdog from 03c is armed (WatchdogTimerStatus) on every node"
  for ip in "${NODES_ARR[@]}"; do
    ws="$(talosctl -n "$ip" get watchdogtimerstatus -o yaml 2> /dev/null)"
    if grep -q "timeout: ${RPI5_WATCHDOG_TIMEOUT}" <<< "$ws" && grep -q 'device:' <<< "$ws"; then
      ok "${ip}: watchdog armed ($(awk '/device:/{print $2}' <<< "$ws"), ${RPI5_WATCHDOG_TIMEOUT})"
    else
      bad "${ip}: watchdog not armed"
    fi
  done
}

# The DaemonSet tolerates not-ready nodes and uses the host network, so it needs no CNI.
apply_nic_keeper() {
  local cm_before cm_after
  say "applying the ${NIC_KEEPER_NAME} DaemonSet (the runtime half)"
  if [ ! -f "$NIC_KEEPER_MANIFEST" ]; then
    bad "missing ${NIC_KEEPER_MANIFEST}"
    return 0
  fi
  # resourceVersion only moves when the object actually changed, so this detects a real edit to the loop
  # script without parsing apply output or needing a `diff` binary the kubectl image does not ship.
  cm_before="$(kubectl -n "$NIC_KEEPER_NS" get cm "$NIC_KEEPER_NAME" -o jsonpath='{.metadata.resourceVersion}' 2> /dev/null)"
  if kubectl apply -f - < "$NIC_KEEPER_MANIFEST" > /dev/null; then
    ok "applied ${NIC_KEEPER_MANIFEST}"
    cm_after="$(kubectl -n "$NIC_KEEPER_NS" get cm "$NIC_KEEPER_NAME" -o jsonpath='{.metadata.resourceVersion}' 2> /dev/null)"
    # A ConfigMap change does not restart the pods that mounted it, so roll them. Skipped on a first apply
    # (no cm_before), where the pods are starting with the new script anyway.
    if [ -n "$cm_before" ] && [ "$cm_before" != "$cm_after" ]; then
      say "the loop script changed, rolling ${NIC_KEEPER_NAME}"
      kubectl -n "$NIC_KEEPER_NS" rollout restart "daemonset/${NIC_KEEPER_NAME}" > /dev/null 2>&1 \
        && kubectl -n "$NIC_KEEPER_NS" rollout status "daemonset/${NIC_KEEPER_NAME}" --timeout="${ROLLOUT_TIMEOUT}s" > /dev/null 2>&1 \
        && ok "${NIC_KEEPER_NAME} rolled" \
        || bad "${NIC_KEEPER_NAME} did not roll out within ${ROLLOUT_TIMEOUT}s (kubectl -n ${NIC_KEEPER_NS} describe ds ${NIC_KEEPER_NAME})"
    fi
  else
    bad "could not apply ${NIC_KEEPER_MANIFEST}"
  fi
}

print_result() {
  if [ "$FAIL" -eq 0 ]; then
    echo "NIC fix in effect, both halves: the 03c machine config for offloads, rings and watchdog, and the"
    echo "  ${NIC_KEEPER_NAME} DaemonSet. See docs/03_operating_system.md."
  else
    echo "Some checks failed. A missing offload, ring or watchdog setting means the node runs a config"
    echo "  without the rpi5 patch: run make reapply-talos-config NODE=<host>."
  fi
}

# ---- main ----

check_prerequisites
select_target_nodes
verify_ethernet_config
verify_watchdog
apply_nic_keeper

summary
print_result
[ "$FAIL" -eq 0 ]
