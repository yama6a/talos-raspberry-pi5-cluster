#!/usr/bin/env bash
# One-shot orchestrator for a FIRST-TIME cluster init. Assumes freshly-flashed nodes (03a done) sitting
# in MAINTENANCE mode, and takes them to a configured Talos cluster with etcd bootstrapped. One confirmation
# up front, non-interactive after that. To wipe a RUNNING cluster first, use DANGEROUS_reset_talos_cluster.sh.
#
# Sequence (STEP N/5):
#   1. maintenance preflight        : every node must answer the INSECURE API, fast-fail if any is already
#                                      configured (that is a rebuild, not a bootstrap)
#   2. 03b_talos_boot_verify.sh     : deep per-node verify, a hard gate BEFORE we archive creds or mint PKI
#   3. archive local creds          : move the old secrets into secrets/backup_<ts>/ so 03c mints a NEW PKI
#   4. 03c_talos_cluster_config.sh  : generate fresh config, apply, bootstrap etcd, write kube/talosconfig
#   5. 03d_nic_hardening.sh         : NIC hardening
#
# Ends with a cluster whose nodes are configured and etcd bootstrapped, and a kubeconfig in secrets/. The
# nodes stay NotReady until a CNI lands, which is the first thing the platform repo does. See the handoff
# printed at the end.
#
# Every step aborts on the first failure with a resume hint.
# Archiving secrets.yaml makes 03c mint a NEW Talos CA, so the archived talosconfig and kubeconfig stop
# working. That is intended for a genuine from-scratch init.
#
# Needs Docker (host networking), yq, kubectl.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # say/die/warn/ok + CLUSTER_DIR + the inventory node arrays + secret .env keys + REPO_ROOT
cd "$REPO_ROOT" || exit 1           # run from the repo root (git ops, relative hints); set -e is off, so guard cd

# ---- knobs ------------------------------------------------------------------
STEP=0; STEP_TOTAL=5                           # shared step counter (common.sh step/run_step); bump TOTAL if you add/remove a step
STEP_DIR="$SCRIPT_DIR"                          # every step script is a sibling of this orchestrator in lib/shell/
KUBECONFIG_FILE="${CLUSTER_DIR}/kubeconfig"
MAINT_TIMEOUT=30                               # secs/node to confirm maintenance API before giving up

require docker yq kubectl
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${STEP_DIR}/03c_talos_cluster_config.sh" ] || die "missing 03c, run from the repo root"
IPS=("${ALL_IPS[@]}")   # workers included: 03c configures them in the same pass, so they must be up front too

cat <<EOF

This will BOOTSTRAP a FIRST-TIME Talos cluster on freshly-flashed nodes:
  nodes   : ${IPS[*]}
  archive : secrets.yaml + kubeconfig + talosconfig + sealed-secrets-master.key (+ 03c scratch)
            -> secrets/backup_<timestamp>/   (03c then mints a NEW Talos CA; the old creds stop working)
  flow    : preflight -> 03b verify -> archive -> 03c (config + etcd) -> 03d (NIC hardening)
  result  : a configured cluster + a kubeconfig. Nodes stay NotReady until the platform repo installs a CNI.

Requires nodes in MAINTENANCE mode (03a done; 03b boot-verify is run for you below). To wipe a RUNNING
cluster first, abort and use DANGEROUS_reset_talos_cluster.sh.
EOF
confirm_word_always BOOTSTRAP || { echo "aborted (phew!)."; exit 0; }

say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null 2>&1 || true

# A maintenance node answers the INSECURE API; a CONFIGURED one does NOT (see 03c). So requiring the
# insecure `version` to succeed proves the node is fresh-in-maintenance, not already running a cluster.
# --insecure needs no talosconfig, so this works even though we're about to archive it.
step "checking every node is in MAINTENANCE mode (fresh-init preflight)"
for ip in "${IPS[@]}"; do
  printf '   %-15s ' "$ip"
  wait_talos_api "$ip" "$MAINT_TIMEOUT" insecure 3 || { echo "NOT IN MAINTENANCE"; \
    die "${ip} is not answering the maintenance API within ${MAINT_TIMEOUT}s. Bootstrap needs freshly-flashed nodes in maintenance mode (03a/03b). If this is a RUNNING cluster, use DANGEROUS_rebuild_cluster.sh to wipe first."; }
  echo "maintenance"
done
ok "all nodes in maintenance"

# STEP 1 only proves the maintenance API answers. 03b additionally asserts each node booted OUR image
# (Talos version + rpi5 overlay in the kernel cmdline), sees its NVMe, and has its wired NIC: exactly the
# failure modes that would otherwise surface confusingly deep inside 03c/04. It's a one-shot snapshot (no
# wait of its own), which is why STEP 1's maintenance poll runs first. Fatal run_step: 03b exits non-zero
# on any FAIL, so we die here, before archiving creds / minting fresh PKI, rather than proceed on a bad node.
run_step "boot-verify every node (our image/NIC/NVMe/overlay)" "$STEP_DIR" 03b_talos_boot_verify.sh

# Clears secrets/ of every file holding PKI so 03c generates a FRESH secrets.yaml, and with it a new CA. Moves EVERY file present (incl. dotfiles like a stray .env.other-secrets) into the dated backup,
# so nothing lingers to make 03c reuse the old identity, and there is no fixed allowlist to keep in sync now that
# 03c/03d's render scratch lives in an OS temp dir, not here. Skips DIRECTORIES (so prior backup_<ts>/ dirs
# are never re-nested into the new one) and .DS_Store (macOS noise, not a cred).
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_SUBDIR="${CLUSTER_DIR}/backup_${TS}"
step "archiving existing creds -> ${BACKUP_SUBDIR}"
mkdir -p "$BACKUP_SUBDIR"
moved=0
for path in "${CLUSTER_DIR}"/* "${CLUSTER_DIR}"/.[!.]*; do
  [ -e "$path" ] || continue                       # glob matched nothing (nullglob off)
  [ -d "$path" ] && continue                        # files only; skips backup_<ts>/ and any other dirs
  f="$(basename "$path")"
  [ "$f" = ".DS_Store" ] && continue                # macOS noise, leave it
  mv "$path" "${BACKUP_SUBDIR}/" && moved=$((moved+1)) || die "could not archive ${f}"
done
if [ "$moved" -gt 0 ]; then ok "archived ${moved} file(s)"; else rmdir "$BACKUP_SUBDIR" 2>/dev/null; ok "nothing to archive (already a clean start)"; fi

run_step "fresh PKI, apply config, bootstrap etcd" "$STEP_DIR" 03c_talos_cluster_config.sh
run_step "NIC hardening (EEE/watchdog)"            "$STEP_DIR" 03d_nic_hardening.sh

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<HANDOFF

The cluster is configured and etcd is bootstrapped. Nodes are NotReady on purpose: nothing has installed a
CNI yet, and that is where this repo stops.

  kubeconfig : ${KUBECONFIG_FILE}
  check      : KUBECONFIG=${KUBECONFIG_FILE} kubectl get nodes   # all present, all NotReady

Next, in the platform repo (https://github.com/yama6a/offgrid), which installs the CNI and then delivers
everything else from git:

  make bootstrap-cluster

It reads the same kubeconfig, because secrets/ is a symlink to the same off-repo store in both repos. If
that symlink is missing on the platform side, point it at the same directory before running.
HANDOFF
else
  echo "Some steps failed, see above. Fix and re-run: this orchestrator is re-runnable from the top."
fi
[ "$FAIL" -eq 0 ]
