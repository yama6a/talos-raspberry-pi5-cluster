#!/usr/bin/env bash
# Renders the Talos machine config from inventory.yaml + versions.env + .env and applies it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
03c_talos_cluster_config.sh [--reapply] [<host>]
  (none)      nodes must be in MAINTENANCE: apply insecurely, bootstrap etcd, write the kubeconfig.
              First bring-up, or a rebuild after DANGEROUS_reset_talos_cluster.sh.
  --reapply   nodes must already be RUNNING: apply over the Talos API with --mode auto, never bootstrap.
              How a config change reaches a live cluster without wiping it.
  <host>      that node ALONE, from maintenance, without bootstrapping etcd. For putting a replaced node
              back into an existing cluster, or adding one. certSANs and the talosconfig endpoints still
              come from the FULL control-plane list, or the node would trust an apiserver cert naming only
              itself and talosctl would forget the others.

A worker gets a strict subset of the control-plane config: no VIP, no certSANs, no etcd tuning, no bootstrap.
Which one a node gets comes from its role in inventory.yaml. Requires docker with host networking.
EOF
}

# ---- knobs ----
OUTDIR="${CLUSTER_DIR}"    # durable creds; the lib's talosctl() mounts it as /work, so /work == ${OUTDIR}
# Throwaway render scratch in an OS temp dir, so nothing lingers next to the durable creds and there is
# nothing to clean up. talosctl() mounts it at /scratch. Survives a mid-run failure for inspection.
TALOS_SCRATCH="$(mktemp -d)"

CLUSTER="$CLUSTER_NAME"; DISK="$INSTALL_DISK"; EPHEMERAL="$EPHEMERAL_SIZE"; VIP="$CLUSTER_VIP"; KVER="$KUBERNETES_VERSION"

# ---- state ----
REAPPLY=false             # set by parse_args
JOIN_ONE=""
TARGETS=()
REGISTRIES_BLOCK=""       # set by build_registries_block

# ---- functions ----

parse_args() {
  # Control-plane nodes first, so etcd exists before a worker tries to join it.
  TARGETS=("${CP_HOSTS[@]}" "${WORKER_HOSTS[@]}")
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --reapply) REAPPLY=true; shift ;;
      -*)        die "unknown flag: $1 (see --help)" ;;
      *)         JOIN_ONE="$1"; shift ;;
    esac
  done
  if [ -n "$JOIN_ONE" ]; then
    [ -n "${NODE_ROLE[$JOIN_ONE]:-}" ] || die "unknown node '${JOIN_ONE}': inventory.yaml has ${ALL_HOSTS[*]}"
    TARGETS=("$JOIN_ONE")
  fi
}

print_plan() {
  local h
  echo "Scratch:  ${TALOS_SCRATCH}   (throwaway render files; OS-reaped)"
  echo "== Talos cluster setup (talosctl ${TALOSCTL_VERSION}, dockerized) =="
  echo "Cluster:  ${CLUSTER}     VIP: ${VIP}     NIC: ${IFACE}     k8s: ${KVER}"
  echo "Disk:     ${DISK}        EPHEMERAL cap: ${EPHEMERAL}"
  for h in "${TARGETS[@]}"; do
    printf '  %-12s %-16s %-13s %s\n' "$h" "${NODE_IP[$h]}" "${NODE_ROLE[$h]}" "${NODE_TYPE[$h]}"
  done
  if [ "$REAPPLY" = true ]; then
    echo "Mode:     REAPPLY to running nodes (--mode auto), NOT bootstrapping etcd"
  elif [ -n "$JOIN_ONE" ]; then
    echo "Mode:     joining ${JOIN_ONE} ONLY, from maintenance, NOT bootstrapping etcd"
  fi
  echo "Output:   ${OUTDIR}"
}

# Baked into the machine config so the kubelet authenticates EVERY pull from GHCR on every node, with no
# per-namespace imagePullSecrets. A read:packages PULL token for YOUR private images; the Talos image package
# is public and needs none. Lands only in the gitignored secrets dir. GitHub Packages only authenticates with
# a CLASSIC token.
build_registries_block() {
  echo
  if [ -z "${GITHUB_GHCR_PULL_TOKEN_SECRET}" ]; then
    echo "  -> GITHUB_GHCR_PULL_TOKEN_SECRET empty in .env; skipping registry auth (fine if every image is PUBLIC)."
    return 0
  fi
  REGISTRIES_BLOCK="$(cat <<EOF
  registries:
    config:
      ${GHCR_SERVER}:
        auth:
          username: ${GHCR_USER}
          password: ${GITHUB_GHCR_PULL_TOKEN_SECRET}
EOF
)"
  echo "  -> ${GHCR_SERVER} auth (from .env GITHUB_GHCR_PULL_TOKEN_SECRET) baked into the machine config for all nodes."
}

# The cluster's PKI, and the ONE sticky artifact here: everything else is disposable scratch re-rendered from
# it each run. Generated once and never rotated, so the cluster identity survives every re-run.
# With no secrets.yaml but a pre-split controlplane.yaml present, EXTRACT the bundle from it: a plain
# `gen secrets` would mint a NEW PKI that no longer matches the live nodes and would lock us out.
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

# Rendered FRESH each run from the durable secrets plus the CURRENT versions.env and .env, which is why the
# config is split from the secrets: a version bump actually reaches the nodes instead of being frozen into a
# controlplane.yaml we kept from last time. --with-secrets reuses secrets.yaml, so this never rotates PKI.
# The worker base is not passed --install-image: the ref differs per hardware type, so it is patched per node
# at apply time instead.
render_base_configs() {
  talosctl gen config "${CLUSTER}" "https://${VIP}:6443" \
    --with-secrets secrets.yaml \
    --install-disk "${DISK}" \
    --kubernetes-version "${KVER}" \
    --output-types controlplane,talosconfig \
    --force
  # gen config emits talosconfig (durable) and controlplane.yaml (throwaway) into the same dir; move the
  # throwaway one out so the secrets dir keeps only durable creds.
  mv "${OUTDIR}/controlplane.yaml" "${TALOS_SCRATCH}/controlplane.yaml"

  if [ "${#WORKER_HOSTS[@]}" -gt 0 ]; then
    talosctl gen config "${CLUSTER}" "https://${VIP}:6443" \
      --with-secrets secrets.yaml \
      --install-disk "${DISK}" \
      --kubernetes-version "${KVER}" \
      --output-types worker \
      --force
    mv "${OUTDIR}/worker.yaml" "${TALOS_SCRATCH}/worker.yaml"
  fi
}

# Set immediately, because `gen config` above just rewrote talosconfig and a freshly generated one has NO
# endpoints. Doing it here rather than after the apply means aborting anywhere below still leaves a usable
# talosconfig. Real control-plane IPs, not the VIP; a worker cannot proxy the Talos API so it is never an
# endpoint, and `-n <worker-ip>` still reaches it through one of these.
set_talosconfig_endpoints() {
  talosctl config endpoint "${CP_IPS[@]}"
  talosctl config node "${CP_IPS[0]}"
}

# certSANs name the VIP and the CONTROL-PLANE ips only: a worker serves no apiserver.
write_control_plane_patch() {
  local certsans
  certsans="$(printf '      - %s\n' "${VIP}" "${CP_IPS[@]}")"
cat > "${TALOS_SCRATCH}/cp-patch.yaml" <<EOF
machine:
${REGISTRIES_BLOCK}
  kubelet:
    # Talos runs the kubelet in a container and does NOT auto-propagate /var/mnt mounts into it, so without
    # this bind a CSI driver's pods cannot see the disk. rshared means mounts made inside the bind are
    # visible on the host too, which a driver that creates one sub-mount per volume needs.
    extraMounts:
      - destination: /var/mnt/storage
        type: bind
        source: /var/mnt/storage
        options: [bind, rshared, rw]
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
  # The defaults trigger spurious leader elections during the cold-boot I/O storm: storage replicas, database
  # startup and image pulls all saturate the single NVMe, etcd fsync stalls past a second, followers time out,
  # and the election burst lags every watch and informer. Raised 5x, keeping election at 10x heartbeat.
  etcd:
    extraArgs:
      heartbeat-interval: "500"    # ms (etcd default 100)
      election-timeout: "5000"     # ms (etcd default 1000)
  # Both keys come from DISABLE_FLANNEL_AND_KUBE_PROXY in .env: 'none'/true leaves the CNI to be installed
  # separately (a replacement that also takes over kube-proxy), 'flannel'/false keeps the Talos built-in.
  network:
    cni:
      name: ${CNI_NAME}
  proxy:
    disabled: ${PROXY_DISABLED}
  apiServer:
    # Talos audit-logs at Metadata for EVERYTHING by default, which is ~1GB a day per node, mostly leader-election
    # leases and controller reads. Narrowed to writes of real objects, which is ~1.5% of that and is the part
    # worth keeping: who created, changed or deleted what.
    auditPolicy:
      apiVersion: audit.k8s.io/v1
      kind: Policy
      omitStages: [RequestReceived] # one event per request instead of two
      rules:
        - level: None
          verbs: [get, list, watch] # reads: the bulk of the volume, and nothing here reads them
        - level: None
          resources:
            - group: coordination.k8s.io
              resources: [leases] # leader election + kubelet heartbeats: 65% of the default log on its own
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

# The same kubelet mounts and KubePrism, and nothing else. A worker carries no VIP (so no interfaces block
# either, which keeps a NIC name we cannot predict out of the config), no certSANs, no etcd and no CNI/proxy
# keys: those are control-plane bootstrap settings a worker never reads.
write_worker_patch() {
  [ "${#WORKER_HOSTS[@]}" -gt 0 ] || return 0
cat > "${TALOS_SCRATCH}/worker-patch.yaml" <<EOF
machine:
${REGISTRIES_BLOCK}
  kubelet:
    # Same bind as the control plane: a storage layer runs on every node that carries a disk, and the
    # kubelet cannot see /var/mnt without it.
    extraMounts:
      - destination: /var/mnt/storage
        type: bind
        source: /var/mnt/storage
        options: [bind, rshared, rw]
  features:
    kubePrism:
      enabled: true
      port: 7445
EOF
}

# Cap EPHEMERAL, then let 'storage' take the whole remainder: no maxSize, so it claims what is left, once, at
# provision time. Talos provisions a volume ONCE, so renaming this on a live cluster orphans the old partition
# rather than renaming it.
# Every node carries a disk, so the volume layout does not vary by role and both bases get the same docs.
write_volume_config() {
cat > "${TALOS_SCRATCH}/volumes.yaml" <<EOF
---
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  maxSize: ${EPHEMERAL}
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: storage
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
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

# A maintenance node answers --insecure; a CONFIGURED one does not, and a freshly-reset node cannot boot
# configured because STATE is wiped, so this is never fooled by the pre-reset instance: it blocks until the
# node is genuinely back in maintenance. After a reset the nodes wipe and reboot asynchronously, so without
# this the insecure apply would fail on one that has not come back yet.
wait_for_maintenance() {
  local host ip
  say "waiting for nodes in maintenance (up to 5 min each)..."
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    wait_talos_api "$ip" 300 insecure \
      || { echo "TIMEOUT"; die "${ip} not in maintenance after 300s. If it is already RUNNING, you want --reapply."; }
    echo "ready"
  done
}

# The exact opposite test: the node must answer SECURELY, which proves it already holds our PKI and is not
# sitting in maintenance waiting to be initialised.
assert_nodes_running() {
  local host ip
  say "checking the target nodes are running and hold our PKI"
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    talosctl -e "$ip" -n "$ip" version >/dev/null 2>&1 \
      || die "${ip} does not answer the secure API, so it is not a running node of this cluster. Drop --reapply to initialise it from maintenance."
    echo "running"
  done
}

# Maintenance is the only window where the hardware is visible before the config commits to a disk. REPORTS
# rather than asserts, because the point is to work with hardware this repo has never seen: the NIC name is
# firmware-dependent and nothing here depends on it. The install disk is the exception, since getting that
# wrong writes the wrong device.
report_hardware() {
  local host ip disks n
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    say "${host} (${ip}, ${NODE_TYPE[$host]}) hardware"
    talosctl -e "$ip" -n "$ip" get cpus  --insecure 2>/dev/null | tail -n +2 | sed 's/^/   cpu   /' || true
    talosctl -e "$ip" -n "$ip" get links --insecure 2>/dev/null | tail -n +2 | sed 's/^/   link  /' || true
    disks="$(talosctl -e "$ip" -n "$ip" get disks --insecure 2>/dev/null || true)"
    printf '%s\n' "$disks" | tail -n +2 | sed 's/^/   disk  /'
    grep -qE "[[:space:]/]${EXPECT_DISK}([[:space:]]|\$)" <<< "$disks" \
      || die "${host} has no ${EXPECT_DISK}; --install-disk ${DISK} would write a device that is not there"
    n="$(grep -oE '[[:space:]]nvme[0-9]+n[0-9]+[[:space:]]' <<< "$disks" | wc -l | tr -d ' ')"
    [ "${n:-0}" -le 1 ] || warn "${host} shows ${n} NVMe disks; the volume diskSelector matches on transport, so it could pick either"
  done
}

# Hostname goes through the HostnameConfig document (needs Talos >= 1.12), not machine.network.hostname: gen
# config already ships a HostnameConfig (auto: stable), and setting both errors with "static hostname is
# already set in v1alpha1 config".
# install.image and the instance-type label are per NODE, not per role, so they ride in their own patch: the
# installer ref follows the hardware type, and nic-keeper selects on the label.
# -e is not optional on the secure path: `gen config --force` rewrote talosconfig and a freshly generated one
# carries NO endpoints. Without it the apply dies with "failed to determine endpoints". --insecure never
# needed it, since that dials -n directly.
apply_to() {
  local host="$1"; shift
  local ip="${NODE_IP[$host]}" base rpatch npatch
  case "${NODE_ROLE[$host]}" in
    controlplane) base="/scratch/cp.yaml";     rpatch="/scratch/cp-patch.yaml" ;;
    worker)       base="/scratch/worker.yaml"; rpatch="/scratch/worker-patch.yaml" ;;
  esac
  npatch="$(printf '{"machine":{"install":{"image":"%s"},"nodeLabels":{"node.kubernetes.io/instance-type":"%s"}}}' \
            "$(installer_ref_for "$host")" "${NODE_TYPE[$host]}")"
  talosctl apply-config -e "${ip}" -n "${ip}" -f "$base" \
    -p @"$rpatch" \
    -p "$npatch" \
    -p '{"apiVersion":"v1alpha1","kind":"HostnameConfig","hostname":"'"${host}"'","auto":"off"}' \
    "$@"
}

# Unlike a bring-up, this is being done to a cluster that is currently serving, so show the diff and make the
# operator confirm.
confirm_reapply() {
  local host answer
  say "dry run: what each node WOULD do with this config"
  for host in "${TARGETS[@]}"; do
    echo "   --- ${host} (${NODE_IP[$host]}) ---"
    apply_to "$host" --mode auto --dry-run 2>&1 | sed 's/^/   /'
  done
  # Talos provisions a volume once and, with `grow` unset as it is here, never changes an existing volume's
  # size. So an EPHEMERAL_SIZE edit applies to a NEW node and silently does nothing to these.
  warn "volume sizes are fixed at provision time; changing them here reaches new nodes only, not these"
  printf '>> apply to %d running node(s)? some changes reboot. type yes: ' "${#TARGETS[@]}"
  read -r answer </dev/tty 2>/dev/null || answer=""
  [ "$answer" = "yes" ] || die "aborted, nothing applied"
}

apply_configs() {
  local host
  for host in "${TARGETS[@]}"; do
    say "applying ${NODE_ROLE[$host]} config to ${host} (${NODE_IP[$host]})"
    if [ "$REAPPLY" = true ]; then apply_to "$host" --mode auto
    else                           apply_to "$host" --insecure
    fi
  done
}

# apply-config from maintenance reboots each node; it comes back serving the API SECURELY with our PKI, so a
# secure `version` succeeding is the ready signal. Beats guessing a fixed wait. In --reapply the same test
# covers both outcomes: --mode auto reboots only when the change needs it, and a node that never went away
# passes on the first poll.
wait_for_configured() {
  local host ip
  say "waiting for nodes to settle into their configured state (up to 5 min each)..."
  sleep 10   # let any reboot actually begin (avoids a false 'ready' before it goes down)
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    wait_talos_api "$ip" 300 secure \
      || { echo "TIMEOUT"; die "${ip} never came back, check its console/power"; }
    echo "ready"
  done
  sleep 10
}

bootstrap_etcd_and_fetch_kubeconfig() {
  talosctl bootstrap -n "${CP_IPS[0]}"   # ONCE, on the first control-plane node only
  sleep 10
  say "waiting for cluster health (a few minutes)..."
  talosctl health --wait-timeout 10m || warn "health timed out, verify with kubectl below"
  talosctl kubeconfig .
  say "Done."
  echo "   talosconfig: ${OUTDIR}/talosconfig   (export TALOSCONFIG=${OUTDIR}/talosconfig)"
  echo "   kubeconfig:  ${OUTDIR}/kubeconfig    (export KUBECONFIG=${OUTDIR}/kubeconfig && kubectl get nodes)"
  echo "   to make that your default kubectl context instead:  make merge-kubeconfig"
}

print_reapply_result() {
  say "reapplied to ${#TARGETS[@]} node(s). Nothing was bootstrapped: the cluster was already running."
  say "Verify: make check-health   and   make talosctl -- -n <ip> get mc v1alpha1 -o yaml"
}

print_join_result() {
  if [ "${NODE_ROLE[$JOIN_ONE]}" = worker ]; then
    say "${JOIN_ONE} has its config and is rebooting into it; its kubelet registers on its own."
  else
    say "${JOIN_ONE} has its config and is rebooting into it; it joins etcd on its own."
  fi
  say "Not bootstrapping and not re-fetching the kubeconfig: this cluster already exists."
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
  report_hardware    # reads over the insecure API, which a running node refuses
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
