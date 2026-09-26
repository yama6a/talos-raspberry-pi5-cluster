#!/usr/bin/env bash
# Hardens the Pi 5 `macb` NIC (siderolabs/sbc-raspberrypi #91): machine config from the live NIC, then nic-keeper.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
HW_TYPE="rpi5"          # the macb wedge is Pi 5-only
OUTDIR="${CLUSTER_DIR}" # talosctl() mounts it as /work
# Discovery output and patch files. talosctl() mounts it at /scratch. Kept after a failure.
TALOS_SCRATCH="$(mktemp -d)"
KUBECTL_IMAGE="registry.k8s.io/kubectl:v${KUBERNETES_VERSION}" # matches the cluster version. The tag needs the v
# renovate: datasource=docker
DEBUG_IMAGE="alpine:3.24" # the probe pod installs ethtool into it
WATCHDOG_TIMEOUT="15s"    # Talos minimum 10s, Pi hardware maximum about 15s
APPLY_MODE="no-reboot"    # never silently reboot control-plane nodes
SETTLE_GRACE=90           # secs before probing. Earlier probes count answers from before the NIC bounce
SETTLE_WAIT=180           # secs to poll for a steady API over the VIP, after the grace
SETTLE_STREAK=3           # consecutive /readyz answers required
SETTLE_INTERVAL=10        # secs between /readyz probes
# TCP segmentation, generic segmentation and receive coalescing, as kernel feature names. EthernetConfig
# rejects the broader names `ethtool -k` prints.
OFFLOAD_KEYS=(tx-tcp-segmentation tx-generic-segmentation rx-gro)
PROBE_NS="kube-system" # Talos exempts kube-system from Pod Security
PROBE_POD="nic-hw-probe"
NIC_KEEPER_NAME="nic-keeper" # ConfigMap + DaemonSet share the name
NIC_KEEPER_MANIFEST="${REPO_ROOT}/lib/k8s/nic-keeper.yaml"
ROLLOUT_TIMEOUT=300                   # secs to wait for the DaemonSet to roll after a loop-script change
PATCH_FILE="nic-hardening-patch.yaml" # written into TALOS_SCRATCH (=/scratch in the container)
DEL_FILE="nic-eth-delete.yaml"

# ---- state ----
PROBE_UP=0   # the EXIT trap reads it
NODES_ARR=() # set by select_target_nodes
NODE0_IP=""
NODE0_NAME=""
ST="" # set by discover_nic, an `ethernetstatus -o yaml` blob
RX_MAX=""
TX_MAX=""
RINGS_OK=0
FEATURES=()
WD_DEV="" # set by probe_eee_and_watchdog
WD_T=""
ETH_DESIRED=0 # set by generate_patches

# ---- functions ----

# Dockerized and matched to the cluster version. Shadows any host kubectl on purpose, so none is needed.
kubectl() { docker run --rm -i --network host -v "${OUTDIR}:/work" \
  -e KUBECONFIG=/work/kubeconfig "${KUBECTL_IMAGE}" "$@"; }

cleanup() {
  [ "$PROBE_UP" = 1 ] && kubectl delete pod "$PROBE_POD" -n "$PROBE_NS" \
    --ignore-not-found --now > /dev/null 2>&1
  PROBE_UP=0
}

# Parsers over a `get ethernetstatus -o yaml` blob.
eth_status() { talosctl -n "$1" get ethernetstatus "$IFACE" -o yaml 2> /dev/null; }
ring_max() { awk -v k="$2-max:" '/^    rings:/{r=1} r&&$1==k{print $2;exit}' <<< "$1"; } # $1=blob $2=rx|tx
ring_cur() { awk -v k="$2:" '/^    rings:/{r=1} r&&$1==k{print $2;exit}' <<< "$1"; }
feat_val() { awk -v k="$2:" '$1==k{print $2;exit}' <<< "$1"; } # on|off
feat_fixed() { grep -qE "^[[:space:]]*$2:[[:space:]]+(on|off)[[:space:]]+\[fixed\]" <<< "$1"; }

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
  local h nodeinfo
  for h in "${ALL_HOSTS[@]}"; do [ "${NODE_TYPE[$h]}" = "$HW_TYPE" ] && NODES_ARR+=("${NODE_IP[$h]}"); done
  [ "${#NODES_ARR[@]}" -gt 0 ] || die "no node in inventory.yaml has type ${HW_TYPE}, so there is no macb NIC to harden"
  echo "   nodes: ${NODES_ARR[*]}"
  NODE0_IP="${NODES_ARR[0]}"
  nodeinfo="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2> /dev/null)"
  [ -n "$nodeinfo" ] || die "kubectl could not list nodes (check ${OUTDIR}/kubeconfig)"
  NODE0_NAME="$(awk -v ip="$NODE0_IP" '$2==ip{print $1; exit}' <<< "$nodeinfo")"
  [ -n "$NODE0_NAME" ] || die "no k8s node has InternalIP ${NODE0_IP}"
}

discover_nic() {
  local k v
  say "discovering ${IFACE} rings + offload keys (talosctl get ethernetstatus)"
  ST="$(eth_status "$NODE0_IP")"
  [ -n "$ST" ] || die "no EthernetStatus for ${IFACE} on ${NODE0_IP}"
  RX_MAX="$(ring_max "$ST" rx)"
  TX_MAX="$(ring_max "$ST" tx)"
  case "${RX_MAX:-}:${TX_MAX:-}" in [0-9]*:[0-9]*) RINGS_OK=1 ;; esac
  [ "$RINGS_OK" = 1 ] && echo "   rings max: rx=${RX_MAX} tx=${TX_MAX}" || echo "   rings: no usable max, skipping rings"
  for k in "${OFFLOAD_KEYS[@]}"; do
    v="$(feat_val "$ST" "$k")"
    if [ -n "$v" ] && ! feat_fixed "$ST" "$k"; then FEATURES+=("$k"); fi
  done
  [ "${#FEATURES[@]}" -gt 0 ] && echo "   offloads to disable: ${FEATURES[*]}" || echo "   no settable TSO/GSO/GRO keys found"
}

# A short-lived privileged pod reads only what has no Talos resource: EEE and the watchdog device.
start_probe_pod() {
  say "probe pod on ${NODE0_NAME} (${NODE0_IP}), EEE + watchdog device"
  kubectl delete pod "$PROBE_POD" -n "$PROBE_NS" --ignore-not-found --now > /dev/null 2>&1
  cat << EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${PROBE_POD}, namespace: ${PROBE_NS} }
spec:
  hostNetwork: true
  nodeName: ${NODE0_NAME}
  restartPolicy: Never
  tolerations: [ { operator: Exists } ]
  containers:
  - name: probe
    image: ${DEBUG_IMAGE}
    securityContext: { privileged: true }
    command: ["/bin/sh","-c","apk add --no-cache ethtool >/dev/null 2>&1 || true; exec sleep infinity"]
    volumeMounts: [ { name: dev, mountPath: /dev } ]
  volumes: [ { name: dev, hostPath: { path: /dev } } ]
EOF
  PROBE_UP=1
  kubectl wait --for=condition=Ready "pod/${PROBE_POD}" -n "$PROBE_NS" --timeout=120s > /dev/null \
    || die "probe pod did not become Ready on ${NODE0_NAME}"
  pexec 'i=0; until command -v ethtool >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 60 ] && exit 1; sleep 2; done' \
    > /dev/null || die "probe image lacks ethtool (override DEBUG_IMAGE, or give the node registry access)"
}

pexec() { kubectl exec -n "$PROBE_NS" "$PROBE_POD" -- sh -c "$1"; }

wd_secs() { case "$1" in *s) echo "${1%s}" ;; *) echo "$1" ;; esac }

probe_eee_and_watchdog() {
  local disc="${TALOS_SCRATCH}/nic-discovery.txt"
  pexec '
  echo "=== EEE ==="; ethtool --show-eee '"$IFACE"' 2>&1
  echo "=== WATCHDOG_DEV ==="; ls -1 /dev/watchdog* 2>&1
' > "$disc" || die "discovery exec failed"

  WD_DEV="$(grep -E '^/dev/watchdog0$' "$disc" | head -1)"
  [ -z "$WD_DEV" ] && WD_DEV="$(grep -E '^/dev/watchdog' "$disc" | head -1)"
  WD_DEV="${WD_DEV:-/dev/watchdog0}"
  WD_T="$(wd_secs "$WATCHDOG_TIMEOUT")"
  case "$WD_T" in '' | *[!0-9]*) WD_T=15 ;; esac
  [ "$WD_T" -lt 10 ] && WD_T=10
  echo "   watchdog: device=${WD_DEV} timeout=${WD_T}s (Talos minimum 10s, Pi hardware maximum about 15s)"

  say "EEE status, for reference only. nic-keeper turns EEE off"
  sed -n '/=== EEE ===/,/=== WATCHDOG_DEV ===/p' "$disc" | sed '1d;$d' | sed 's/^/   /'
  cleanup
  echo "   probe pod removed"
}

# EthernetConfig is deleted, then added again, so its features map is exact. A patch merges maps, so a stale
# key would linger and fail the whole ethtool reconcile with "bit name not found".
generate_patches() {
  local k
  if [ "$RINGS_OK" = 1 ] || [ "${#FEATURES[@]}" -gt 0 ]; then ETH_DESIRED=1; fi
  say "generating patches"
  if [ "$ETH_DESIRED" = 1 ]; then
    {
      echo "apiVersion: v1alpha1"
      echo "kind: EthernetConfig"
      echo "name: ${IFACE}"
      echo '$patch: delete'
    } > "${TALOS_SCRATCH}/${DEL_FILE}"
  fi
  {
    if [ "$ETH_DESIRED" = 1 ]; then
      echo "apiVersion: v1alpha1"
      echo "kind: EthernetConfig"
      echo "name: ${IFACE}"
      [ "$RINGS_OK" = 1 ] && {
        echo "rings:"
        echo "  rx: ${RX_MAX}"
        echo "  tx: ${TX_MAX}"
      }
      if [ "${#FEATURES[@]}" -gt 0 ]; then
        echo "features:"
        for k in "${FEATURES[@]}"; do echo "  ${k}: false"; done
      fi
      echo "---"
    fi
    echo "apiVersion: v1alpha1"
    echo "kind: WatchdogTimerConfig"
    echo "device: ${WD_DEV}"
    echo "timeout: ${WD_T}s"
  } > "${TALOS_SCRATCH}/${PATCH_FILE}"
  sed 's/^/   /' "${TALOS_SCRATCH}/${PATCH_FILE}"
}

# Patches documents only, so the rest of the machine config that 03c applied stays as it is.
apply_patches() {
  local ip out rc
  say "applying to all nodes (talosctl patch mc, --mode ${APPLY_MODE})"
  for ip in "${NODES_ARR[@]}"; do
    # Delete the old EthernetConfig first. On a fresh node "not found" is fine.
    [ "$ETH_DESIRED" = 1 ] && talosctl -n "$ip" patch mc --patch "@/scratch/${DEL_FILE}" --mode "${APPLY_MODE}" > /dev/null 2>&1
    out="$(talosctl -n "$ip" patch mc --patch "@/scratch/${PATCH_FILE}" --mode "${APPLY_MODE}" 2>&1)"
    rc=$?
    if [ $rc -eq 0 ]; then ok "patched ${ip}"; else
      bad "patch ${ip} failed: $(tail -1 <<< "$out")"
      grep -qi 'reboot' <<< "$out" && echo "         (the change needs a reboot. Refused, this script never reboots a node)"
    fi
  done
}

verify_ethernet_config() {
  local ip st rxok txok offok k
  say "verify, EthernetConfig in effect (EthernetStatus) on every node"
  for ip in "${NODES_ARR[@]}"; do
    st=""
    rxok=0
    txok=0
    offok=0
    for _ in $( # up to about 150s, because the EthernetSpec controller backs off after errors
      seq 1 30
    ); do
      st="$(eth_status "$ip")"
      if [ "$RINGS_OK" = 1 ]; then
        [ "$(ring_cur "$st" rx)" = "$RX_MAX" ] && rxok=1 || rxok=0
        [ "$(ring_cur "$st" tx)" = "$TX_MAX" ] && txok=1 || txok=0
      else
        rxok=1
        txok=1
      fi
      offok=1
      for k in "${FEATURES[@]}"; do [ "$(feat_val "$st" "$k")" = off ] || offok=0; done
      [ $rxok = 1 ] && [ $txok = 1 ] && [ $offok = 1 ] && break
      sleep 3
    done
    for k in "${FEATURES[@]}"; do
      [ "$(feat_val "$st" "$k")" = off ] && ok "${ip}: ${k} = off" || bad "${ip}: ${k} still $(feat_val "$st" "$k")"
    done
    if [ "$RINGS_OK" = 1 ]; then
      [ $rxok = 1 ] && ok "${ip}: ring rx = ${RX_MAX} (max)" || bad "${ip}: ring rx = $(ring_cur "$st" rx) != ${RX_MAX}"
      [ $txok = 1 ] && ok "${ip}: ring tx = ${TX_MAX} (max)" || bad "${ip}: ring tx = $(ring_cur "$st" tx) != ${TX_MAX}"
    fi
  done
}

verify_watchdog() {
  local ip ws
  say "verify, watchdog armed (WatchdogTimerStatus) on every node"
  for ip in "${NODES_ARR[@]}"; do
    ws="$(talosctl -n "$ip" get watchdogtimerstatus -o yaml 2> /dev/null)"
    if grep -q "timeout: ${WD_T}s" <<< "$ws" && grep -q 'device:' <<< "$ws"; then
      ok "${ip}: watchdog armed ($(awk '/device:/{print $2}' <<< "$ws"), ${WD_T}s)"
    else
      bad "${ip}: watchdog not armed"
    fi
  done
}

# The ring change bounces end0, which carries the VIP, and the checks above hit node IPs directly. A fixed
# grace first, because probing at once counts answers from before the bounce. Then several answers in a row.
wait_for_api_steady() {
  local streak=0 deadline
  say "letting the NIC reconfig take effect before probing (grace ${SETTLE_GRACE}s)..."
  sleep "$SETTLE_GRACE"
  say "waiting for the control-plane API to answer steadily over the VIP"
  deadline=$(($(date +%s) + SETTLE_WAIT))
  until [ "$streak" -ge "$SETTLE_STREAK" ]; do
    if kubectl get --raw='/readyz' > /dev/null 2>&1; then streak=$((streak + 1)); else streak=0; fi
    [ "$streak" -ge "$SETTLE_STREAK" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || break
    printf '.'
    sleep "$SETTLE_INTERVAL"
  done
  echo
  [ "$streak" -ge "$SETTLE_STREAK" ] \
    && ok "control-plane API steady over the VIP (${SETTLE_STREAK}x consecutive /readyz)" \
    || bad "API not steady ${SETTLE_STREAK}x within ${SETTLE_WAIT}s. Let the NIC and VIP settle"
}

# Runs only once the API is steady, since this is its first write. The DaemonSet tolerates not-ready nodes
# and uses the host network, so it needs no CNI.
apply_nic_keeper() {
  local cm_before cm_after
  say "applying the ${NIC_KEEPER_NAME} DaemonSet (the runtime half)"
  if [ ! -f "$NIC_KEEPER_MANIFEST" ]; then
    bad "missing ${NIC_KEEPER_MANIFEST}"
    return 0
  fi
  # resourceVersion only moves when the object actually changed, so this detects a real edit to the loop
  # script without parsing apply output or needing a `diff` binary the kubectl image does not ship.
  cm_before="$(kubectl -n "$PROBE_NS" get cm "$NIC_KEEPER_NAME" -o jsonpath='{.metadata.resourceVersion}' 2> /dev/null)"
  if kubectl apply -f - < "$NIC_KEEPER_MANIFEST" > /dev/null; then
    ok "applied ${NIC_KEEPER_MANIFEST}"
    cm_after="$(kubectl -n "$PROBE_NS" get cm "$NIC_KEEPER_NAME" -o jsonpath='{.metadata.resourceVersion}' 2> /dev/null)"
    # A ConfigMap change does not restart the pods that mounted it, so roll them. Skipped on a first apply
    # (no cm_before), where the pods are starting with the new script anyway.
    if [ -n "$cm_before" ] && [ "$cm_before" != "$cm_after" ]; then
      say "the loop script changed, rolling ${NIC_KEEPER_NAME}"
      kubectl -n "$PROBE_NS" rollout restart "daemonset/${NIC_KEEPER_NAME}" > /dev/null 2>&1 \
        && kubectl -n "$PROBE_NS" rollout status "daemonset/${NIC_KEEPER_NAME}" --timeout="${ROLLOUT_TIMEOUT}s" > /dev/null 2>&1 \
        && ok "${NIC_KEEPER_NAME} rolled" \
        || bad "${NIC_KEEPER_NAME} did not roll out within ${ROLLOUT_TIMEOUT}s (kubectl -n ${PROBE_NS} describe ds ${NIC_KEEPER_NAME})"
    fi
  else
    bad "could not apply ${NIC_KEEPER_MANIFEST}"
  fi
}

print_result() {
  if [ "$FAIL" -eq 0 ]; then
    echo "NIC fixes applied and verified, both halves:"
    echo "  machine config for offloads, rings and watchdog, and the ${NIC_KEEPER_NAME} DaemonSet."
    echo "  See docs/03_operating_system.md."
  else
    echo "Some checks failed. A 'patch mc' that needed a reboot was refused, see above."
    echo "If the watchdog is not armed, lower WATCHDOG_TIMEOUT. The Pi hardware maximum is about 15s."
  fi
}

# ---- main ----

trap cleanup EXIT

check_prerequisites
select_target_nodes
discover_nic
start_probe_pod
probe_eee_and_watchdog
generate_patches
apply_patches
verify_ethernet_config
verify_watchdog
wait_for_api_steady
apply_nic_keeper

summary
print_result
[ "$FAIL" -eq 0 ]
