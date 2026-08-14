#!/usr/bin/env bash
# Mitigates the Pi 5 `macb` NIC wedge (siderolabs/sbc-raspberrypi #91): discovers the NIC's facts on a live
# node, generates machine config from them, applies, verifies, then applies the runtime half (nic-keeper).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
HW_TYPE="rpi5"                             # the macb wedge is Pi 5-only
OUTDIR="${CLUSTER_DIR}"                    # talosconfig + kubeconfig; the lib's talosctl() mounts it as /work
# Throwaway scratch (discovery capture + patch files). talosctl() mounts it at /scratch, so host paths use
# ${TALOS_SCRATCH} and the talosctl patch args use /scratch. Survives a failure for inspection, OS-reaped.
TALOS_SCRATCH="$(mktemp -d)"
KUBECTL_IMAGE="registry.k8s.io/kubectl:v${KUBERNETES_VERSION}"   # pinned to the cluster's k8s version, no skew; the tag needs the 'v'
# renovate: datasource=docker
DEBUG_IMAGE="alpine:3.24"                  # probe pod; apk-installs ethtool
WATCHDOG_TIMEOUT="15s"                     # floored to 10s (Talos min); Pi hw max ~15s
APPLY_MODE="no-reboot"                     # never silently reboot control-plane nodes
SETTLE_GRACE=90                            # secs before probing: the NIC reconfig takes a while to bounce
                                           # end0/the VIP, and probing early banks a streak off the old API
SETTLE_WAIT=180                            # secs to poll for the VIP/API to steady (after the grace above)
SETTLE_STREAK=3                            # consecutive /readyz hits required (one success isn't enough)
SETTLE_INTERVAL=10                         # secs between /readyz probes
# The NIC batching up outbound TCP, the kernel batching up outbound packets, and the NIC coalescing inbound
# ones. Spelled as kernel feature names, which is what EthernetConfig accepts, NOT the broader umbrella names
# `ethtool -k` prints: copying those gives you a config Talos rejects.
OFFLOAD_KEYS=(tx-tcp-segmentation tx-generic-segmentation rx-gro)
PROBE_NS="kube-system"                     # Talos exempts kube-system from Pod Security
PROBE_POD="nic-hw-probe"
NIC_KEEPER_NAME="nic-keeper"               # ConfigMap + DaemonSet share the name
NIC_KEEPER_MANIFEST="${REPO_ROOT}/lib/k8s/nic-keeper.yaml"
ROLLOUT_TIMEOUT=300                        # secs to wait for the DaemonSet to roll after a loop-script change
PATCH_FILE="nic-hardening-patch.yaml"      # written into TALOS_SCRATCH (=/scratch in the container)
DEL_FILE="nic-eth-delete.yaml"

# ---- state ----
PROBE_UP=0          # the EXIT trap reads it
NODES_ARR=()        # set by select_target_nodes
NODE0_IP=""
NODE0_NAME=""
ST=""               # set by discover_nic, an `ethernetstatus -o yaml` blob
RX_MAX=""
TX_MAX=""
RINGS_OK=0
FEATURES=()
WD_DEV=""           # set by probe_eee_and_watchdog
WD_T=""
ETH_DESIRED=0       # set by generate_patches

# ---- functions ----

# Dockerized kubectl, pinned to the cluster's k8s version, mounting the secrets dir. Shadows any host kubectl
# deliberately: this repo never assumes one is installed.
kubectl()  { docker run --rm -i --network host -v "${OUTDIR}:/work" \
  -e KUBECONFIG=/work/kubeconfig "${KUBECTL_IMAGE}" "$@"; }

cleanup() { [ "$PROBE_UP" = 1 ] && kubectl delete pod "$PROBE_POD" -n "$PROBE_NS" \
  --ignore-not-found --now >/dev/null 2>&1; PROBE_UP=0; }

# Parsers over a `get ethernetstatus -o yaml` blob.
eth_status()  { talosctl -n "$1" get ethernetstatus "$IFACE" -o yaml 2>/dev/null; }
ring_max()    { awk -v k="$2-max:" '/^    rings:/{r=1} r&&$1==k{print $2;exit}' <<<"$1"; }  # $1=blob $2=rx|tx
ring_cur()    { awk -v k="$2:"     '/^    rings:/{r=1} r&&$1==k{print $2;exit}' <<<"$1"; }
feat_val()    { awk -v k="$2:" '$1==k{print $2;exit}' <<<"$1"; }                            # on|off
feat_fixed()  { grep -qE "^[[:space:]]*$2:[[:space:]]+(on|off)[[:space:]]+\[fixed\]" <<<"$1"; }

check_prerequisites() {
  say "checking prerequisites"
  require docker
  docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
  [ -f "${OUTDIR}/talosconfig" ] || die "missing ${OUTDIR}/talosconfig, run 03c first"
  [ -f "${OUTDIR}/kubeconfig" ]  || die "missing ${OUTDIR}/kubeconfig, run 03c first"
}

# Nodes of the Pi 5 hardware type, not the talosconfig endpoints: everything here is macb-specific, and the
# endpoints list is control-plane-only, so it would both miss a Pi worker and target a node with another NIC.
select_target_nodes() {
  local h nodeinfo
  for h in "${ALL_HOSTS[@]}"; do [ "${NODE_TYPE[$h]}" = "$HW_TYPE" ] && NODES_ARR+=("${NODE_IP[$h]}"); done
  [ "${#NODES_ARR[@]}" -gt 0 ] || die "no node in inventory.yaml has type ${HW_TYPE}, so there is no macb NIC to harden"
  echo "   nodes: ${NODES_ARR[*]}"
  NODE0_IP="${NODES_ARR[0]}"
  nodeinfo="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null)"
  [ -n "$nodeinfo" ] || die "kubectl could not list nodes (check ${OUTDIR}/kubeconfig)"
  NODE0_NAME="$(awk -v ip="$NODE0_IP" '$2==ip{print $1; exit}' <<< "$nodeinfo")"
  [ -n "$NODE0_NAME" ] || die "no k8s node has InternalIP ${NODE0_IP}"
}

discover_nic() {
  local k v
  say "discovering ${IFACE} rings + offload keys (talosctl get ethernetstatus)"
  ST="$(eth_status "$NODE0_IP")"
  [ -n "$ST" ] || die "no EthernetStatus for ${IFACE} on ${NODE0_IP}"
  RX_MAX="$(ring_max "$ST" rx)"; TX_MAX="$(ring_max "$ST" tx)"
  case "${RX_MAX:-}:${TX_MAX:-}" in [0-9]*:[0-9]*) RINGS_OK=1;; esac
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
  kubectl delete pod "$PROBE_POD" -n "$PROBE_NS" --ignore-not-found --now >/dev/null 2>&1
cat <<EOF | kubectl apply -f - >/dev/null
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
  kubectl wait --for=condition=Ready "pod/${PROBE_POD}" -n "$PROBE_NS" --timeout=120s >/dev/null \
    || die "probe pod did not become Ready on ${NODE0_NAME}"
  pexec 'i=0; until command -v ethtool >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 60 ] && exit 1; sleep 2; done' \
    >/dev/null || die "probe image lacks ethtool (override DEBUG_IMAGE, or give the node registry access)"
}

pexec() { kubectl exec -n "$PROBE_NS" "$PROBE_POD" -- sh -c "$1"; }

wd_secs() { case "$1" in *s) echo "${1%s}";; *) echo "$1";; esac; }

probe_eee_and_watchdog() {
  local disc="${TALOS_SCRATCH}/nic-discovery.txt"
  pexec '
  echo "=== EEE ==="; ethtool --show-eee '"$IFACE"' 2>&1
  echo "=== WATCHDOG_DEV ==="; ls -1 /dev/watchdog* 2>&1
' > "$disc" || die "discovery exec failed"

  WD_DEV="$(grep -E '^/dev/watchdog0$' "$disc" | head -1)"
  [ -z "$WD_DEV" ] && WD_DEV="$(grep -E '^/dev/watchdog' "$disc" | head -1)"
  WD_DEV="${WD_DEV:-/dev/watchdog0}"
  WD_T="$(wd_secs "$WATCHDOG_TIMEOUT")"; case "$WD_T" in ''|*[!0-9]*) WD_T=15;; esac
  [ "$WD_T" -lt 10 ] && WD_T=10
  echo "   watchdog: device=${WD_DEV} timeout=${WD_T}s (Talos min 10s; Pi hw max ~15s)"

  say "EEE status (captured for the deferred DaemonSet, NOT applied now)"
  sed -n '/=== EEE ===/,/=== WATCHDOG_DEV ===/p' "$disc" | sed '1d;$d' | sed 's/^/   /'
  cleanup; echo "   probe pod removed"
}

# EthernetConfig is delete-then-readd so the features map is authoritative each run: strategic merge UNIONS
# maps, so a stale or renamed feature key would linger and fail the WHOLE ethtool reconcile ("bit name not
# found"), leaving every offload unchanged.
generate_patches() {
  local k
  if [ "$RINGS_OK" = 1 ] || [ "${#FEATURES[@]}" -gt 0 ]; then ETH_DESIRED=1; fi
  say "generating patches"
  if [ "$ETH_DESIRED" = 1 ]; then
    { echo "apiVersion: v1alpha1"; echo "kind: EthernetConfig"; echo "name: ${IFACE}"; echo '$patch: delete'; } > "${TALOS_SCRATCH}/${DEL_FILE}"
  fi
  {
    if [ "$ETH_DESIRED" = 1 ]; then
      echo "apiVersion: v1alpha1"; echo "kind: EthernetConfig"; echo "name: ${IFACE}"
      [ "$RINGS_OK" = 1 ] && { echo "rings:"; echo "  rx: ${RX_MAX}"; echo "  tx: ${TX_MAX}"; }
      if [ "${#FEATURES[@]}" -gt 0 ]; then echo "features:"; for k in "${FEATURES[@]}"; do echo "  ${k}: false"; done; fi
      echo "---"
    fi
    echo "apiVersion: v1alpha1"; echo "kind: WatchdogTimerConfig"
    echo "device: ${WD_DEV}"; echo "timeout: ${WD_T}s"
  } > "${TALOS_SCRATCH}/${PATCH_FILE}"
  sed 's/^/   /' "${TALOS_SCRATCH}/${PATCH_FILE}"
}

# Patched at DOCUMENT level, never a full re-apply, so the live certSAN fix survives.
apply_patches() {
  local ip out rc
  say "applying to all nodes (talosctl patch mc, --mode ${APPLY_MODE})"
  for ip in "${NODES_ARR[@]}"; do
    # Drop any prior EthernetConfig first (clears stale keys); "not found" on fresh nodes is fine.
    [ "$ETH_DESIRED" = 1 ] && talosctl -n "$ip" patch mc --patch "@/scratch/${DEL_FILE}" --mode "${APPLY_MODE}" >/dev/null 2>&1
    out="$(talosctl -n "$ip" patch mc --patch "@/scratch/${PATCH_FILE}" --mode "${APPLY_MODE}" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then ok "patched ${ip}"; else
      bad "patch ${ip} failed: $(tail -1 <<< "$out")"
      grep -qi 'reboot' <<< "$out" && echo "         (a reboot would be required, refusing; not rebooting control-plane nodes)"
    fi
  done
}

verify_ethernet_config() {
  local ip st rxok txok offok k
  say "verify, EthernetConfig in effect (EthernetStatus) on every node"
  for ip in "${NODES_ARR[@]}"; do
    st=""; rxok=0; txok=0; offok=0
    for _ in $(seq 1 30); do                   # up to ~150s (the EthernetSpec controller backs off after errors)
      st="$(eth_status "$ip")"
      if [ "$RINGS_OK" = 1 ]; then
        [ "$(ring_cur "$st" rx)" = "$RX_MAX" ] && rxok=1 || rxok=0
        [ "$(ring_cur "$st" tx)" = "$TX_MAX" ] && txok=1 || txok=0
      else rxok=1; txok=1; fi
      offok=1; for k in "${FEATURES[@]}"; do [ "$(feat_val "$st" "$k")" = off ] || offok=0; done
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
    ws="$(talosctl -n "$ip" get watchdogtimerstatus -o yaml 2>/dev/null)"
    if grep -q "timeout: ${WD_T}s" <<< "$ws" && grep -q 'device:' <<< "$ws"; then
      ok "${ip}: watchdog armed ($(awk '/device:/{print $2}' <<<"$ws"), ${WD_T}s)"
    else
      bad "${ip}: watchdog not armed"
    fi
  done
}

# The ring-resize re-inits the macb rings, which bounces end0 for a few seconds, and the control-plane VIP
# rides on end0. The checks above only confirm the CONFIG landed (talosctl hits node IPs directly), not that
# the VIP is back. Two stages, both needed: a fixed grace first, because probing immediately banks a streak
# off the OLD still-up API; then poll until it answers SETTLE_STREAK times in a row, because a single good hit
# is exactly what fooled an earlier version of this.
wait_for_api_steady() {
  local streak=0 deadline
  say "letting the NIC reconfig take effect before probing (grace ${SETTLE_GRACE}s)..."
  sleep "$SETTLE_GRACE"
  say "waiting for the control-plane API to be steady over the VIP (post-NIC-reconfig settle)"
  deadline=$(( $(date +%s) + SETTLE_WAIT ))
  until [ "$streak" -ge "$SETTLE_STREAK" ]; do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then streak=$((streak+1)); else streak=0; fi
    [ "$streak" -ge "$SETTLE_STREAK" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || break
    printf '.'; sleep "$SETTLE_INTERVAL"
  done
  echo
  [ "$streak" -ge "$SETTLE_STREAK" ] \
    && ok  "control-plane API steady over the VIP (${SETTLE_STREAK}x consecutive /readyz)" \
    || bad "API not steady ${SETTLE_STREAK}x within ${SETTLE_WAIT}s, let the NIC/VIP settle"
}

# The runtime half: EEE LPI-wake, silent wedge detection and the post-recovery socket stall need a live agent,
# which machine config cannot reach. Applied only once the API is proven steady, since this is the first thing
# to write to it. It runs before any CNI because the DaemonSet tolerates node.kubernetes.io/not-ready and the
# pod is hostNetwork.
apply_nic_keeper() {
  local cm_before cm_after
  say "applying the ${NIC_KEEPER_NAME} DaemonSet (the runtime half)"
  if [ ! -f "$NIC_KEEPER_MANIFEST" ]; then
    bad "missing ${NIC_KEEPER_MANIFEST}"
    return 0
  fi
  # resourceVersion only moves when the object actually changed, so this detects a real edit to the loop
  # script without parsing apply output or needing a `diff` binary the kubectl image does not ship.
  cm_before="$(kubectl -n "$PROBE_NS" get cm "$NIC_KEEPER_NAME" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)"
  if kubectl apply -f - < "$NIC_KEEPER_MANIFEST" >/dev/null; then
    ok "applied ${NIC_KEEPER_MANIFEST}"
    cm_after="$(kubectl -n "$PROBE_NS" get cm "$NIC_KEEPER_NAME" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)"
    # A ConfigMap change does not restart the pods that mounted it, so roll them. Skipped on a first apply
    # (no cm_before), where the pods are starting with the new script anyway.
    if [ -n "$cm_before" ] && [ "$cm_before" != "$cm_after" ]; then
      say "the loop script changed, rolling ${NIC_KEEPER_NAME}"
      kubectl -n "$PROBE_NS" rollout restart "daemonset/${NIC_KEEPER_NAME}" >/dev/null 2>&1 \
        && kubectl -n "$PROBE_NS" rollout status "daemonset/${NIC_KEEPER_NAME}" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null 2>&1 \
        && ok "${NIC_KEEPER_NAME} rolled" \
        || bad "${NIC_KEEPER_NAME} did not roll out within ${ROLLOUT_TIMEOUT}s (kubectl -n ${PROBE_NS} describe ds ${NIC_KEEPER_NAME})"
    fi
  else
    bad "could not apply ${NIC_KEEPER_MANIFEST}"
  fi
}

print_result() {
  if [ "$FAIL" -eq 0 ]; then
    echo "NIC defences applied + verified, both halves:"
    echo "  machine config (offloads, rings, watchdog) + the ${NIC_KEEPER_NAME} DaemonSet"
    echo "  (EEE-off, link-watchdog, 'ss -K'). See 03_operating_system.md."
  else
    echo "Some checks failed. If 'patch mc' demanded a reboot it was refused (see above);"
    echo "if the watchdog wasn't armed, lower WATCHDOG_TIMEOUT (Pi hw max ~15s)."
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
