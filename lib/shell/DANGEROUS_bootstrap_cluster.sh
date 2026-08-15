#!/usr/bin/env bash
# DANGEROUS: one-shot first-time cluster init, from freshly-flashed nodes in maintenance to a configured
# Talos cluster with etcd bootstrapped. One confirmation up front, non-interactive after that.
# To wipe a RUNNING cluster first, use DANGEROUS_reset_talos_cluster.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
cd "$REPO_ROOT" || exit 1           # git ops and relative hints below; set -e is off, so guard the cd

# ---- knobs ----
STEP=0; STEP_TOTAL=5                # common.sh step/run_step; bump TOTAL if you add or remove a step
STEP_DIR="$SCRIPT_DIR"              # every step script is a sibling of this orchestrator
KUBECONFIG_FILE="${CLUSTER_DIR}/kubeconfig"
MAINT_TIMEOUT=30                    # secs/node to confirm the maintenance API before giving up
IPS=("${ALL_IPS[@]}")               # workers included: 03c configures them in the same pass

# ---- state ----
CNI_RESULT=""    # set by describe_cni_outcome
CNI_STATE=""
NODES_HINT=""

# ---- functions ----

check_prerequisites() {
  require docker yq kubectl
  docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
  [ -f "${STEP_DIR}/03c_talos_cluster_config.sh" ] || die "missing 03c, run from the repo root"
}

describe_cni_outcome() {
  if [ "$DISABLE_FLANNEL_AND_KUBE_PROXY" = "true" ]; then
    CNI_RESULT="Nodes stay NotReady until a CNI is installed."
    CNI_STATE="Nodes are NotReady on purpose: nothing has installed a CNI yet, and that is where this repo stops."
    NODES_HINT="# all present, all NotReady"
  else
    CNI_RESULT="Talos' built-in Flannel is on, so nodes reach Ready on their own."
    CNI_STATE="Flannel and kube-proxy are on, so the nodes reach Ready without a CNI install. That gets you pod
and service networking and nothing else: no LoadBalancer, no L2 announcements, no gateway."
    NODES_HINT="# all present, Ready once Flannel settles"
  fi
}

# Archiving secrets.yaml makes 03c mint a NEW Talos CA, so the archived talosconfig and kubeconfig stop
# working. Intended for a genuine from-scratch init.
confirm_bootstrap() {
cat <<EOF

This will BOOTSTRAP a FIRST-TIME Talos cluster on freshly-flashed nodes:
  nodes   : ${IPS[*]}
  archive : every file in secrets/ (secrets.yaml, kubeconfig, talosconfig, ...)
            -> secrets/backup_<timestamp>/   (03c then mints a NEW Talos CA; the old creds stop working)
  flow    : preflight -> 03b verify -> archive -> 03c (config + etcd) -> 03d (NIC hardening)
  result  : a configured cluster + a kubeconfig. ${CNI_RESULT}

Requires nodes in MAINTENANCE mode (03a done; 03b boot-verify is run for you below). To wipe a RUNNING
cluster first, abort and use DANGEROUS_reset_talos_cluster.sh.
EOF
  confirm_word_always BOOTSTRAP || { echo "aborted (phew!)."; exit 0; }
  say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
  docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null 2>&1 || true
}

# A maintenance node answers the INSECURE API; a CONFIGURED one does NOT. So requiring insecure `version` to
# succeed proves the node is fresh-in-maintenance, not already running a cluster. --insecure needs no
# talosconfig, so this works even though we are about to archive it.
assert_nodes_in_maintenance() {
  local ip
  step "checking every node is in MAINTENANCE mode (fresh-init preflight)"
  for ip in "${IPS[@]}"; do
    printf '   %-15s ' "$ip"
    wait_talos_api "$ip" "$MAINT_TIMEOUT" insecure 3 || { echo "NOT IN MAINTENANCE"; \
      die "${ip} is not answering the maintenance API within ${MAINT_TIMEOUT}s. Bootstrap needs freshly-flashed nodes in maintenance mode (03a/03b). If this is a RUNNING cluster, use DANGEROUS_reset_talos_cluster.sh to wipe first."; }
    echo "maintenance"
  done
  ok "all nodes in maintenance"
}

# Fatal run_step, and run BEFORE any creds are archived: 03b asserts each node booted OUR image, sees its
# install disk and has its wired NIC, which are exactly the failure modes that otherwise surface deep inside 03c.
boot_verify_nodes() {
  run_step "boot-verify every node (our image/NIC/install disk/overlay)" "$STEP_DIR" 03b_talos_boot_verify.sh
}

# Moves EVERY file present, including dotfiles, so nothing lingers to make 03c reuse the old identity and
# there is no allowlist to keep in sync. Skips DIRECTORIES, so prior backup_<ts>/ dirs are never re-nested.
archive_existing_creds() {
  local ts backup_subdir path f moved=0
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_subdir="${CLUSTER_DIR}/backup_${ts}"
  step "archiving existing creds -> ${backup_subdir}"
  mkdir -p "$backup_subdir"
  for path in "${CLUSTER_DIR}"/* "${CLUSTER_DIR}"/.[!.]*; do
    [ -e "$path" ] || continue                       # glob matched nothing (nullglob off)
    [ -d "$path" ] && continue
    f="$(basename "$path")"
    [ "$f" = ".DS_Store" ] && continue                # macOS noise, not a cred
    mv "$path" "${backup_subdir}/" && moved=$((moved+1)) || die "could not archive ${f}"
  done
  if [ "$moved" -gt 0 ]; then ok "archived ${moved} file(s)"; else rmdir "$backup_subdir" 2>/dev/null; ok "nothing to archive (already a clean start)"; fi
}

print_handoff() {
  if [ "$FAIL" -eq 0 ]; then
cat <<HANDOFF

The cluster is configured and etcd is bootstrapped. ${CNI_STATE}

  kubeconfig : ${KUBECONFIG_FILE}
  check      : KUBECONFIG=${KUBECONFIG_FILE} kubectl get nodes   ${NODES_HINT}

Point your kubectl at it, and whatever installs the CNI and the rest of the platform takes it from here:

  make merge-kubeconfig                      # merge into ~/.kube/config, make it the active context

The kubeconfig is the handover. Nothing else in this repo is needed by whatever runs on the cluster next.
HANDOFF
  else
    echo "Some steps failed, see above. Fix and re-run: this orchestrator is re-runnable from the top."
  fi
}

# ---- main ----

check_prerequisites
describe_cni_outcome
confirm_bootstrap

assert_nodes_in_maintenance
boot_verify_nodes
archive_existing_creds
run_step "fresh PKI, apply config, bootstrap etcd" "$STEP_DIR" 03c_talos_cluster_config.sh
run_step "NIC hardening (offloads/watchdog + nic-keeper)" "$STEP_DIR" 03d_nic_hardening.sh

summary
print_handoff
[ "$FAIL" -eq 0 ]
