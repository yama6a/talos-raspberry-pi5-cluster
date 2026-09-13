#!/usr/bin/env bash
# Merges secrets/kubeconfig into ~/.kube/config and makes it the active context. The handover out of this
# repo: the kubeconfig is the only thing anything running on the cluster needs from here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
CLUSTER_KC="${CLUSTER_DIR}/kubeconfig"
HOME_KC="${HOME}/.kube/config"

# ---- state ----
TARGET_CTX=""   # set by read_target_context

# ---- functions ----

read_target_context() {
  [ -f "$CLUSTER_KC" ] || die "missing ${CLUSTER_KC}, run step 03 (03c) or 'make bootstrap-cluster' first"
  TARGET_CTX="$(kubectl --kubeconfig "$CLUSTER_KC" config current-context)"
  [ -n "$TARGET_CTX" ] || die "${CLUSTER_KC} has no current-context set"
}

# Entries are named after CLUSTER_NAME, so a second run replaces them rather than piling up.
merge_into_home_kubeconfig() {
  local backup tmp
  umask 077   # everything below writes a file holding cluster admin creds
  mkdir -p "$(dirname "$HOME_KC")"
  if [ ! -f "$HOME_KC" ]; then
    cp "$CLUSTER_KC" "$HOME_KC"     # no ~/.kube/config yet, so a plain copy IS the merge
    ok "created ${HOME_KC} from ${CLUSTER_KC}"
    return 0
  fi
  backup="${HOME_KC}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$HOME_KC" "$backup"
  ok "backed up ${HOME_KC} -> ${backup}"
  # --flatten inlines every cert, including other contexts' file-referenced CAs: the result is self-contained
  # but stops tracking those external files. Merge into a temp and mv, so a failure leaves the original intact.
  tmp="$(mktemp -t kubeconfig-merge.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  KUBECONFIG="${CLUSTER_KC}:${HOME_KC}" kubectl config view --flatten > "$tmp"
  [ -s "$tmp" ] || die "merge produced an empty kubeconfig, ${HOME_KC} left untouched (backup: ${backup})"
  mv "$tmp" "$HOME_KC"
  trap - EXIT
  ok "merged ${CLUSTER_KC} into ${HOME_KC}"
}

# Explicit, rather than relying on --flatten taking current-context from the first KUBECONFIG entry.
select_context() {
  kubectl config use-context "$TARGET_CTX" >/dev/null
  ok "active context: ${TARGET_CTX}"
  say "contexts now in ${HOME_KC}"
  kubectl config get-contexts
}

print_result() {
  say "MERGE COMPLETE"
  echo "   check: kubectl get nodes"
  echo "   next:  install a CNI, then whatever else the cluster runs; both read this context"
}

# ---- main ----

require kubectl
read_target_context
merge_into_home_kubeconfig
select_context
print_result
