#!/usr/bin/env bash
# Merges this cluster's kubeconfig (secrets/kubeconfig, written by 03c) into ~/.kube/config and makes it the
# active context, so plain `kubectl` reaches the cluster with nothing exported.
#
# This is the handover out of this repo, not a convenience: the kubeconfig is the only thing anything running
# on the cluster needs from here, and nothing else in secrets/ ever leaves.
#
# Re-run-safe: the entries are named after CLUSTER_NAME, so a second run replaces them rather than piling up.
# Every run leaves a timestamped backup of the previous ~/.kube/config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require kubectl

CLUSTER_KC="${CLUSTER_DIR}/kubeconfig"
HOME_KC="${HOME}/.kube/config"

[ -f "$CLUSTER_KC" ] || die "missing ${CLUSTER_KC}, run step 03 (03c) or 'make bootstrap-cluster' first"

TARGET_CTX="$(kubectl --kubeconfig "$CLUSTER_KC" config current-context)"
[ -n "$TARGET_CTX" ] || die "${CLUSTER_KC} has no current-context set"

umask 077   # everything below writes a file holding cluster admin creds
mkdir -p "$(dirname "$HOME_KC")"

# No ~/.kube/config yet: a plain copy IS the merge. The one-liner this replaces chained on `cp ~/.kube/config`
# and so silently did nothing on a machine that had never run kubectl.
if [ ! -f "$HOME_KC" ]; then
  cp "$CLUSTER_KC" "$HOME_KC"
  ok "created ${HOME_KC} from ${CLUSTER_KC}"
else
  BACKUP="${HOME_KC}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$HOME_KC" "$BACKUP"
  ok "backed up ${HOME_KC} -> ${BACKUP}"

  # --flatten inlines every cert, including other contexts' file-referenced CAs: the result is self-contained
  # but stops tracking those external files. Merge into a temp and mv, so a failure leaves the original intact.
  TMP="$(mktemp -t kubeconfig-merge.XXXXXX)"
  trap 'rm -f "$TMP"' EXIT
  KUBECONFIG="${CLUSTER_KC}:${HOME_KC}" kubectl config view --flatten > "$TMP"
  [ -s "$TMP" ] || die "merge produced an empty kubeconfig, ${HOME_KC} left untouched (backup: ${BACKUP})"
  mv "$TMP" "$HOME_KC"
  trap - EXIT
  ok "merged ${CLUSTER_KC} into ${HOME_KC}"
fi

# Explicit, rather than relying on --flatten taking current-context from the first KUBECONFIG entry.
kubectl config use-context "$TARGET_CTX" >/dev/null
ok "active context: ${TARGET_CTX}"

say "contexts now in ${HOME_KC}"
kubectl config get-contexts

say "MERGE COMPLETE"
echo "   check: kubectl get nodes"
echo "   next:  install a CNI, then whatever else the cluster runs; both read this context"
