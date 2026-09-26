#!/usr/bin/env bash
# Renders the Talos machine config from inventory.yaml + versions.env + .env and applies it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
03c_talos_cluster_config.sh [--reapply] [<host>]
  (none)      every node in maintenance mode: apply insecurely, bootstrap etcd, write the kubeconfig.
              For the first bring-up, or a rebuild after DANGEROUS_reset_talos_cluster.sh.
  --reapply   every node already running: apply over the Talos API with --mode auto, never bootstrap.
              How a config change reaches a live cluster without wiping it.
  <host>      that node only, from maintenance mode, without bootstrapping etcd. To add a node, or to put
              a replaced one back. certSANs and talosconfig endpoints still come from every control-plane
              node, or the node would trust a cert that names only itself.

A worker gets a subset of the control-plane config: no VIP, no certSANs, no etcd tuning, no bootstrap.
The node's role in inventory.yaml decides which. Needs docker with host networking.
EOF
}

# ---- knobs ----
OUTDIR="${CLUSTER_DIR}" # talosctl() mounts it as /work
# Render files, including the pull token, go to an OS temp dir mounted at /scratch. Kept after a failure.
TALOS_SCRATCH="$(mktemp -d)"

CLUSTER="$CLUSTER_NAME"
EPHEMERAL="$EPHEMERAL_SIZE"
VIP="$CLUSTER_VIP"
KVER="$KUBERNETES_VERSION"

# ---- state ----
REAPPLY=false # set by parse_args
JOIN_ONE=""
TARGETS=()
REGISTRIES_BLOCK="" # set by build_registries_block

# ---- functions ----

parse_args() {
  # Control-plane nodes first, so etcd exists before a worker tries to join it.
  TARGETS=("${CP_HOSTS[@]}" "${WORKER_HOSTS[@]}")
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --reapply)
        REAPPLY=true
        shift
        ;;
      -*) die "unknown flag: $1 (see --help)" ;;
      *)
        JOIN_ONE="$1"
        shift
        ;;
    esac
  done
  if [ -n "$JOIN_ONE" ]; then
    [ -n "${NODE_ROLE[$JOIN_ONE]:-}" ] || die "unknown node '${JOIN_ONE}': inventory.yaml has ${ALL_HOSTS[*]}"
    TARGETS=("$JOIN_ONE")
  fi
}

print_plan() {
  local h
  echo "Scratch:  ${TALOS_SCRATCH}   (render files, removed by the OS)"
  echo "== Talos cluster setup (talosctl ${TALOSCTL_VERSION}, dockerized) =="
  echo "Cluster:  ${CLUSTER}     VIP: ${VIP}     NIC: ${IFACE}     k8s: ${KVER}     EPHEMERAL cap: ${EPHEMERAL}"
  for h in "${TARGETS[@]}"; do
    printf '  %-12s %-16s %-13s %-16s %s\n' "$h" "${NODE_IP[$h]}" "${NODE_ROLE[$h]}" "${NODE_TYPE[$h]}" "${NODE_INSTALL_DISK[$h]}"
  done
  if [ "$REAPPLY" = true ]; then
    echo "Mode:     reapply to running nodes (--mode auto), no etcd bootstrap"
  elif [ -n "$JOIN_ONE" ]; then
    echo "Mode:     joining ${JOIN_ONE} only, from maintenance mode, no etcd bootstrap"
  fi
  echo "Output:   ${OUTDIR}"
}

# Every node authenticates every ghcr.io pull, so no namespace needs imagePullSecrets. GitHub Packages accepts
# only a classic token. It lands in the render scratch dir and the machine config, never in git.
build_registries_block() {
  echo
  if [ -z "${GITHUB_GHCR_PULL_TOKEN_SECRET}" ]; then
    echo "   GITHUB_GHCR_PULL_TOKEN_SECRET is empty in .env, so no registry auth. Fine if every image is public."
    return 0
  fi
  REGISTRIES_BLOCK="$(
    cat << EOF
  registries:
    config:
      ${GHCR_SERVER}:
        auth:
          username: ${GHCR_USER}
          password: ${GITHUB_GHCR_PULL_TOKEN_SECRET}
EOF
  )"
  echo "   ${GHCR_SERVER} auth from GITHUB_GHCR_PULL_TOKEN_SECRET goes into every node's machine config."
}

# The cluster PKI: generated once and never rotated, so the cluster identity survives every re-run.
# With only a controlplane.yaml present, extract from it: a fresh `gen secrets` would not match the live nodes.
ensure_secrets_bundle() {
  [ -f "${OUTDIR}/secrets.yaml" ] && return 0
  if [ -f "${OUTDIR}/controlplane.yaml" ]; then
    say "extracting secrets.yaml from the existing controlplane.yaml (preserves the running cluster's PKI)"
    talosctl gen secrets --from-controlplane-config controlplane.yaml -o secrets.yaml
  else
    say "generating a fresh secrets.yaml (new cluster PKI, created once, never rotated)"
    talosctl gen secrets -o secrets.yaml
  fi
}

# Rendered fresh each run from secrets.yaml and the current versions.env and .env, so a version bump reaches
# the nodes. No --install-image or --install-disk: both follow the node, so apply_to patches them per node.
render_base_configs() {
  talosctl gen config "${CLUSTER}" "https://${VIP}:6443" \
    --with-secrets secrets.yaml \
    --kubernetes-version "${KVER}" \
    --output-types controlplane,talosconfig \
    --force
  # gen config writes controlplane.yaml next to talosconfig. Move it out, so the secrets dir keeps only creds.
  mv "${OUTDIR}/controlplane.yaml" "${TALOS_SCRATCH}/controlplane.yaml"

  if [ "${#WORKER_HOSTS[@]}" -gt 0 ]; then
    talosctl gen config "${CLUSTER}" "https://${VIP}:6443" \
      --with-secrets secrets.yaml \
      --kubernetes-version "${KVER}" \
      --output-types worker \
      --force
    mv "${OUTDIR}/worker.yaml" "${TALOS_SCRATCH}/worker.yaml"
  fi
}

# Right after gen config, which leaves talosconfig with no endpoints, so an abort below still leaves it usable.
# Control-plane IPs, not the VIP. A worker cannot proxy the Talos API.
set_talosconfig_endpoints() {
  talosctl config endpoint "${CP_IPS[@]}"
  talosctl config node "${CP_IPS[0]}"
}

# certSANs name the VIP and the control-plane IPs only. A worker serves no apiserver.
write_control_plane_patch() {
  local certsans
  certsans="$(printf '      - %s\n' "${VIP}" "${CP_IPS[@]}")"
  cat > "${TALOS_SCRATCH}/cp-patch.yaml" << EOF
machine:
${REGISTRIES_BLOCK}
  kubelet:
    # The kubelet runs in a container that does not see /var/mnt, so a CSI driver needs this bind.
    # rshared makes the driver's per-volume mounts visible on the host too.
    extraMounts:
      - destination: /var/mnt/storage
        type: bind
        source: /var/mnt/storage
        options: [bind, rshared, rw]
    # The default GC starts only at 85% of EPHEMERAL. This removes an image unused for a week, counted from
    # kubelet start, not from the pull.
    extraConfig:
      imageMaximumGCAge: 168h
  features:
    kubePrism:
      enabled: true
      port: 7445
  network:
    interfaces:
      - interface: ${IFACE}
        dhcp: true
        vip:
          ip: ${VIP}
cluster:
  allowSchedulingOnControlPlanes: true
  # At the defaults, a cold boot saturates the one NVMe, etcd fsyncs stall past a second, and followers call
  # needless elections that lag every watch. Raised 5x, election still 10x heartbeat.
  etcd:
    extraArgs:
      heartbeat-interval: "500"    # ms (etcd default 100)
      election-timeout: "5000"     # ms (etcd default 1000)
  # From DISABLE_FLANNEL_AND_KUBE_PROXY: none leaves the CNI and kube-proxy to you, flannel keeps Talos' own.
  network:
    cni:
      name: ${CNI_NAME}
  proxy:
    disabled: ${PROXY_DISABLED}
  # Memory runs out first on the 8 GB Pis. Weighting free memory 3:1 sends pods to the node with room, instead
  # of a near-tie decided by CPU requests.
  scheduler:
    config:
      apiVersion: kubescheduler.config.k8s.io/v1
      kind: KubeSchedulerConfiguration
      profiles:
        - schedulerName: default-scheduler
          pluginConfig:
            - name: NodeResourcesFit
              args:
                scoringStrategy:
                  type: LeastAllocated
                  resources:
                    - {name: cpu, weight: 1}
                    - {name: memory, weight: 3}
  apiServer:
    # The Talos default request is far below real use, so the scheduler overpacks the Pis until pods get
    # OOM-killed. cpu is the Talos default.
    resources:
      requests:
        cpu: 200m
        memory: 2Gi
    # Go lets the heap reach twice the live size before it collects. This soft limit collects earlier.
    # Much lower, and a re-list storm would keep the collector running nonstop.
    env:
      GOMEMLIMIT: 1500MiB
    # Talos audits every request by default, mostly leases and controller reads. These rules keep writes to
    # real objects: who created, changed or deleted what.
    auditPolicy:
      apiVersion: audit.k8s.io/v1
      kind: Policy
      omitStages: [RequestReceived] # one event per request instead of two
      rules:
        - level: None
          verbs: [get, list, watch] # most of the volume, and nobody reviews them
        - level: None
          resources:
            - group: coordination.k8s.io
              resources: [leases] # leader election and kubelet heartbeats
        - level: None
          resources:
            - group: ""
              resources: [events, nodes/status, pods/status] # controller status churn, already in metrics
            - group: events.k8s.io
              resources: [events]
        - level: Metadata # never Request or RequestResponse: those log Secret and ConfigMap contents
    certSANs:
${certsans}
EOF
}

# Kubelet mounts, image GC age and KubePrism only. No interfaces block: a worker carries no VIP, and its NIC
# name depends on the firmware.
write_worker_patch() {
  [ "${#WORKER_HOSTS[@]}" -gt 0 ] || return 0
  cat > "${TALOS_SCRATCH}/worker-patch.yaml" << EOF
machine:
${REGISTRIES_BLOCK}
  kubelet:
    # Same bind as the control plane. A storage layer runs on every node with a disk.
    extraMounts:
      - destination: /var/mnt/storage
        type: bind
        source: /var/mnt/storage
        options: [bind, rshared, rw]
    extraConfig:
      imageMaximumGCAge: 168h
  features:
    kubePrism:
      enabled: true
      port: 7445
EOF
}

# Talos provisions each volume once, so renaming one on a live cluster orphans the old partition.
# system_disk follows installDisk. Matching on transport would miss a SATA node or pick the wrong NVMe.
write_volume_config() {
  cat > "${TALOS_SCRATCH}/volumes.yaml" << EOF
---
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
provisioning:
  diskSelector:
    match: system_disk
  maxSize: ${EPHEMERAL}
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: storage
provisioning:
  diskSelector:
    match: system_disk
  minSize: 50GiB
filesystem:
  type: xfs
EOF
  cp "${TALOS_SCRATCH}/controlplane.yaml" "${TALOS_SCRATCH}/cp.yaml"
  cat "${TALOS_SCRATCH}/volumes.yaml" >> "${TALOS_SCRATCH}/cp.yaml"
  if [ "${#WORKER_HOSTS[@]}" -gt 0 ]; then
    cat "${TALOS_SCRATCH}/volumes.yaml" >> "${TALOS_SCRATCH}/worker.yaml"
  fi
}

# Only a maintenance node answers --insecure. After a reset the nodes reboot at their own pace, so this waits
# until each is really back, or the insecure apply fails on a slow one.
wait_for_maintenance() {
  local host ip
  say "waiting for nodes in maintenance (up to 5 min each)..."
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    wait_talos_api "$ip" 300 insecure \
      || {
        echo "timed out"
        die "${ip} not in maintenance after 300s. If it is already running, you want --reapply."
      }
    echo "ready"
  done
}

# The opposite test: a secure answer proves the node already holds our PKI.
assert_nodes_running() {
  local host ip
  say "checking the target nodes are running and hold our PKI"
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    talosctl -e "$ip" -n "$ip" version > /dev/null 2>&1 \
      || die "${ip} does not answer the secure API, so it is not a running node of this cluster. Drop --reapply to initialise it from maintenance."
    echo "running"
  done
}

# Reports rather than asserts: the NIC name depends on firmware and nothing here needs it. The install disk
# is the exception, because the wrong one writes the wrong device.
report_hardware() {
  local host ip disks disk
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    disk="${NODE_INSTALL_DISK[$host]}"
    say "${host} (${ip}, ${NODE_TYPE[$host]}) hardware"
    talosctl -e "$ip" -n "$ip" get cpus --insecure 2> /dev/null | tail -n +2 | sed 's/^/   cpu   /' || true
    talosctl -e "$ip" -n "$ip" get links --insecure 2> /dev/null | tail -n +2 | sed 's/^/   link  /' || true
    disks="$(talosctl -e "$ip" -n "$ip" get disks --insecure 2> /dev/null || true)"
    printf '%s\n' "$disks" | tail -n +2 | sed 's/^/   disk  /'
    grep -qE "[[:space:]/]${disk##*/}([[:space:]]|\$)" <<< "$disks" \
      || die "${host} has no ${disk}, so installing to it would write a device that is not there. Set its installDisk in inventory.yaml to one of the disks listed above."
  done
}

# The hostname goes in a HostnameConfig document (needs Talos >= 1.12). gen config already ships one, and also
# setting machine.network.hostname fails with "static hostname is already set".
# -e is required on the secure path: gen config --force left talosconfig with no endpoints.
apply_to() {
  local host="$1"
  shift
  local ip="${NODE_IP[$host]}" base rpatch npatch
  case "${NODE_ROLE[$host]}" in
    controlplane)
      base="/scratch/cp.yaml"
      rpatch="/scratch/cp-patch.yaml"
      ;;
    worker)
      base="/scratch/worker.yaml"
      rpatch="/scratch/worker-patch.yaml"
      ;;
  esac
  npatch="$(printf '{"machine":{"install":{"image":"%s","disk":"%s"},"nodeLabels":{"node.kubernetes.io/instance-type":"%s"}}}' \
    "$(installer_ref_for "$host")" "${NODE_INSTALL_DISK[$host]}" "${NODE_TYPE[$host]}")"
  talosctl apply-config -e "${ip}" -n "${ip}" -f "$base" \
    -p @"$rpatch" \
    -p "$npatch" \
    -p '{"apiVersion":"v1alpha1","kind":"HostnameConfig","hostname":"'"${host}"'","auto":"off"}' \
    "$@"
}

# The cluster is serving, so show the dry run and ask first.
confirm_reapply() {
  local host answer
  say "dry run: what each node would do with this config"
  for host in "${TARGETS[@]}"; do
    echo "   --- ${host} (${NODE_IP[$host]}) ---"
    apply_to "$host" --mode auto --dry-run 2>&1 | sed 's/^/   /'
  done
  warn "volume sizes are fixed when a node is first configured. A size change here reaches new nodes only"
  printf '>> apply to %d running node(s)? Some changes reboot. Type yes: ' "${#TARGETS[@]}"
  read -r answer < /dev/tty 2> /dev/null || answer=""
  [ "$answer" = "yes" ] || die "aborted, nothing applied"
}

apply_configs() {
  local host
  for host in "${TARGETS[@]}"; do
    say "applying ${NODE_ROLE[$host]} config to ${host} (${NODE_IP[$host]})"
    if [ "$REAPPLY" = true ]; then
      apply_to "$host" --mode auto
    else
      apply_to "$host" --insecure
    fi
  done
}

# A secure `version` answer is the ready signal. With --reapply, a node that did not need a reboot passes at once.
wait_for_configured() {
  local host ip
  say "waiting for nodes to settle into their configured state (up to 5 min each)..."
  sleep 10 # let a reboot start, or the old instance answers ready
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    wait_talos_api "$ip" 300 secure \
      || {
        echo "timed out"
        die "${ip} never came back. Check its console and power"
      }
    echo "ready"
  done
  sleep 10
}

bootstrap_etcd_and_fetch_kubeconfig() {
  talosctl bootstrap -n "${CP_IPS[0]}" # once, on the first control-plane node only
  sleep 10
  say "waiting for cluster health (a few minutes)..."
  talosctl health --wait-timeout 10m || warn "health timed out. Check with kubectl below"
  talosctl kubeconfig .
  say "Done."
  echo "   talosconfig: ${OUTDIR}/talosconfig   (export TALOSCONFIG=${OUTDIR}/talosconfig)"
  echo "   kubeconfig:  ${OUTDIR}/kubeconfig    (export KUBECONFIG=${OUTDIR}/kubeconfig && kubectl get nodes)"
  echo "   to make it your default kubectl context:  make merge-kubeconfig"
}

print_reapply_result() {
  say "reapplied to ${#TARGETS[@]} node(s). Nothing was bootstrapped, the cluster was already running."
  say "Check: make check-health   and   make talosctl -- -n <ip> get mc v1alpha1 -o yaml"
}

print_join_result() {
  if [ "${NODE_ROLE[$JOIN_ONE]}" = worker ]; then
    say "${JOIN_ONE} has its config and is rebooting into it. Its kubelet registers by itself."
  else
    say "${JOIN_ONE} has its config and is rebooting into it. It joins etcd by itself."
  fi
  say "No bootstrap and no new kubeconfig, because this cluster already exists."
}

# ---- main ----

require docker
mkdir -p "${OUTDIR}"
parse_args "$@"
print_plan
build_registries_block

ensure_secrets_bundle
render_base_configs
set_talosconfig_endpoints
write_control_plane_patch
write_worker_patch
write_volume_config

if [ "$REAPPLY" = true ]; then
  assert_nodes_running
  confirm_reapply
else
  wait_for_maintenance
  report_hardware # reads over the insecure API, which a running node refuses
fi

apply_configs
wait_for_configured

if [ "$REAPPLY" = true ]; then
  print_reapply_result
elif [ -n "$JOIN_ONE" ]; then
  print_join_result
else
  bootstrap_etcd_and_fetch_kubeconfig
fi
