#!/usr/bin/env bash
# DANGEROUS: first bring-up, from freshly flashed nodes in maintenance mode to a configured cluster with etcd.
# One confirmation up front, then no prompts. To wipe a running cluster first, use DANGEROUS_reset_talos_cluster.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
cd "$REPO_ROOT" || exit 1

# ---- knobs ----
STEP=0
STEP_TOTAL=5 # the number of step and run_step calls below
STEP_DIR="$SCRIPT_DIR"
KUBECONFIG_FILE="${CLUSTER_DIR}/kubeconfig"
MAINT_TIMEOUT=30      # secs per node to wait for the maintenance API
IPS=("${ALL_IPS[@]}") # workers included, because 03c configures them in the same pass

# ---- state ----
CNI_RESULT="" # set by describe_cni_outcome
CNI_STATE=""
NODES_HINT=""

# ---- functions ----

check_prerequisites() {
  require docker yq kubectl
  docker info > /dev/null 2>&1 || die "docker not responding. Start Rancher or Docker Desktop"
  [ -f "${STEP_DIR}/03c_talos_cluster_config.sh" ] || die "missing 03c. Run from the repo root"
}

describe_cni_outcome() {
  if [ "$DISABLE_FLANNEL_AND_KUBE_PROXY" = "true" ]; then
    CNI_RESULT="Nodes stay NotReady until a CNI is installed."
    CNI_STATE="Nodes are NotReady on purpose: nothing has installed a CNI yet, and that is where this repo stops."
    NODES_HINT="# all present, all NotReady"
  else
    CNI_RESULT="Talos' built-in Flannel is on, so nodes reach Ready on their own."
    CNI_STATE="Flannel and kube-proxy are on, so the nodes reach Ready without a CNI install. That gives pod
and service networking only: no LoadBalancer, no L2 announcements, no gateway."
    NODES_HINT="# all present, Ready once Flannel settles"
  fi
}

# Archiving secrets.yaml makes 03c create a new Talos CA, so the archived talosconfig and kubeconfig stop working.
confirm_bootstrap() {
  cat << EOF

This bootstraps a new Talos cluster on freshly flashed nodes.
  nodes   : ${IPS[*]}
  archive : every file in secrets/, such as secrets.yaml, kubeconfig and talosconfig, moves to
            secrets/backup_<timestamp>/. 03c then creates a new Talos CA, and the old creds stop working.
  steps   : preflight, 03b boot check, archive, 03c config and etcd, 03d NIC hardening
  result  : a configured cluster and a kubeconfig. ${CNI_RESULT}

Every node must be in maintenance mode, after 03a. This script runs the 03b boot check for you. To wipe a
running cluster first, abort and use DANGEROUS_reset_talos_cluster.sh.
EOF
  confirm_word_always BOOTSTRAP || {
    echo "aborted."
    exit 0
  }
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" > /dev/null 2>&1 || true
}

# Only a maintenance node answers the insecure API, so this proves no node already runs a cluster.
assert_nodes_in_maintenance() {
  local ip
  step "checking that every node is in maintenance mode"
  for ip in "${IPS[@]}"; do
    printf '   %-15s ' "$ip"
    wait_talos_api "$ip" "$MAINT_TIMEOUT" insecure 3 || {
      echo "not in maintenance"
      die "${ip} did not answer the maintenance API within ${MAINT_TIMEOUT}s. Bootstrap needs freshly flashed nodes in maintenance mode. For a running cluster, wipe it first with DANGEROUS_reset_talos_cluster.sh."
    }
    echo "maintenance"
  done
  ok "all nodes in maintenance"
}

# Fatal, and before any creds are archived, so a wrong image, disk or NIC stops here and not deep inside 03c.
boot_verify_nodes() {
  run_step "boot check on every node: image, NIC, install disk, overlay" "$STEP_DIR" 03b_talos_boot_verify.sh
}

# Moves every file, dotfiles included, so 03c cannot reuse the old identity. Skips dirs, so old backups stay put.
archive_existing_creds() {
  local ts backup_subdir path f moved=0
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_subdir="${CLUSTER_DIR}/backup_${ts}"
  step "archiving existing creds to ${backup_subdir}"
  mkdir -p "$backup_subdir"
  for path in "${CLUSTER_DIR}"/* "${CLUSTER_DIR}"/.[!.]*; do
    [ -e "$path" ] || continue # the glob matched nothing
    [ -d "$path" ] && continue
    f="$(basename "$path")"
    [ "$f" = ".DS_Store" ] && continue
    mv "$path" "${backup_subdir}/" && moved=$((moved + 1)) || die "could not archive ${f}"
  done
  if [ "$moved" -gt 0 ]; then ok "archived ${moved} file(s)"; else
    rmdir "$backup_subdir" 2> /dev/null
    ok "nothing to archive, already a clean start"
  fi
}

print_handoff() {
  if [ "$FAIL" -eq 0 ]; then
    cat << HANDOFF

The cluster is configured and etcd is bootstrapped. ${CNI_STATE}

  kubeconfig : ${KUBECONFIG_FILE}
  check      : KUBECONFIG=${KUBECONFIG_FILE} kubectl get nodes   ${NODES_HINT}

Point your kubectl at it. Whatever installs the CNI and the rest of the platform takes it from here:

  make merge-kubeconfig                      # merges into ~/.kube/config and makes it the active context

The kubeconfig is the handover. Nothing else in this repo is needed by whatever runs on the cluster next.
HANDOFF
  else
    echo "Some steps failed, see above. Fix them and re-run this script from the top."
  fi
}

# ---- main ----

check_prerequisites
describe_cni_outcome
confirm_bootstrap

assert_nodes_in_maintenance
boot_verify_nodes
archive_existing_creds
run_step "new PKI, apply config, bootstrap etcd" "$STEP_DIR" 03c_talos_cluster_config.sh
run_step "NIC hardening: offloads, watchdog, nic-keeper" "$STEP_DIR" 03d_nic_hardening.sh

summary
print_handoff
[ "$FAIL" -eq 0 ]
