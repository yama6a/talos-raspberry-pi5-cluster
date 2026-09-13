#!/usr/bin/env bash
# Rolling in-place upgrade of the cluster's Kubernetes version, via `talosctl upgrade-k8s`. Reboots nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- state ----
# Control-plane IPs only: upgrade-k8s rolls the control-plane components, and a worker has none of them.
IPS=("${CP_IPS[@]}")

# ---- functions ----

assert_cluster_reachable() {
  require docker
  docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
  [ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig, run step 03 (03c) first"
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null
  talosctl -n "${IPS[0]}" version >/dev/null 2>&1 \
    || die "cluster API not reachable via ${CLUSTER_DIR}/talosconfig (is the cluster up?)"
}

# KUBERNETES_VERSION cannot exceed the pinned Talos's default: bump TALOS_IMAGE_RELEASE and run 03e before
# raising it past that ceiling, or upgrade-k8s rejects it.
confirm_upgrade() {
  local answer
  echo "== Kubernetes upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
  echo "Target: k8s ${KUBERNETES_VERSION}"
  echo "Nodes:  ${IPS[*]}"
  echo
  warn "this rolls the live control plane (apiserver/controller-manager/scheduler + kubelet). No node reboots."
  printf '>> proceed with the k8s upgrade to %s? type yes: ' "${KUBERNETES_VERSION}"
  read -r answer </dev/tty 2>/dev/null || answer=""
  [ "$answer" = "yes" ] || die "aborted"
}

# Cluster-wide: it discovers every control-plane node from the one endpoint and rolls each component in turn,
# gating on API health. A cluster already at the target is a no-op, so this is re-run-safe.
upgrade_kubernetes() {
  say "upgrading cluster to k8s ${KUBERNETES_VERSION}"
  if talosctl -n "${IPS[0]}" upgrade-k8s --to "${KUBERNETES_VERSION}"; then
    ok "cluster upgraded to k8s ${KUBERNETES_VERSION}"
  else
    die "k8s upgrade failed (see above). Cluster left as-is; fix and re-run (idempotent, resumes)."
  fi
}

print_result() {
  say "K8S UPGRADE COMPLETE"
  echo "   target: k8s ${KUBERNETES_VERSION}"
  echo "   verify: kubectl get nodes   (VERSION column shows the new kubelet on every node)"
}

# ---- main ----

assert_cluster_reachable
confirm_upgrade
upgrade_kubernetes
print_result
