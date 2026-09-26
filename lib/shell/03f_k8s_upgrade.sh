#!/usr/bin/env bash
# Rolling upgrade of Kubernetes through `talosctl upgrade-k8s`. Reboots nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- state ----
IPS=("${CP_IPS[@]}") # upgrade-k8s talks to a control-plane node

# ---- functions ----

assert_cluster_reachable() {
  require docker
  docker info > /dev/null 2>&1 || die "docker not responding. Start Rancher or Docker Desktop"
  [ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig. Run 03c first"
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" > /dev/null
  talosctl -n "${IPS[0]}" version > /dev/null 2>&1 \
    || die "cluster API not reachable through ${CLUSTER_DIR}/talosconfig. Is the cluster up?"
}

# upgrade-k8s rejects a version above the pinned Talos release's default. Upgrade Talos first.
confirm_upgrade() {
  local answer
  echo "== Kubernetes upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
  echo "Target: Kubernetes ${KUBERNETES_VERSION}"
  echo "Nodes:  ${IPS[*]}"
  echo
  warn "this rolls the live apiserver, controller-manager, scheduler and kubelet. No node reboots."
  printf '>> proceed with the Kubernetes upgrade to %s? Type yes: ' "${KUBERNETES_VERSION}"
  read -r answer < /dev/tty 2> /dev/null || answer=""
  [ "$answer" = "yes" ] || die "aborted"
}

# Cluster-wide from one endpoint. A cluster already at the target is a no-op, so a re-run is safe.
upgrade_kubernetes() {
  say "upgrading the cluster to Kubernetes ${KUBERNETES_VERSION}"
  if talosctl -n "${IPS[0]}" upgrade-k8s --to "${KUBERNETES_VERSION}"; then
    ok "cluster upgraded to Kubernetes ${KUBERNETES_VERSION}"
  else
    die "Kubernetes upgrade failed, see above. The cluster is left as it is. Fix it and re-run to resume."
  fi
}

print_result() {
  say "Kubernetes upgrade complete"
  echo "   target: Kubernetes ${KUBERNETES_VERSION}"
  echo "   check:  kubectl get nodes   (VERSION shows the new kubelet on every node)"
}

# ---- main ----

assert_cluster_reachable
confirm_upgrade
upgrade_kubernetes
print_result
