#!/usr/bin/env bash
# Rolling-restarts the stateless Deployments, so the scheduler spreads them again after 03e's drains.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
SKIP_NAMESPACES="$REBALANCE_SKIP_NAMESPACES"
# With `Recreate` the old pod releases its volume before the new one needs it, so these volumes can move.
PVC_NAMESPACES="$REBALANCE_PVC_NAMESPACES"
ROLLOUT_TIMEOUT=300 # secs per Deployment
PARALLEL=3          # Deployments restarted at once. Each surges an extra pod, and the Pi 5s run short of RAM

# ---- state ----
SELECTION="" # "DO|SKIP<TAB>reason<TAB>ns<TAB>name" per line
BATCH_PIDS=()
BATCH_NAMES=()

# ---- functions ----

# Restarting onto fewer nodes would only pack the survivors.
assert_all_nodes_schedulable() {
  local nodes_json not_ok node_count
  say "checking every node is Ready and schedulable"
  nodes_json="$(kubectl get nodes -o json)" || die "could not list nodes"
  not_ok="$(printf '%s' "$nodes_json" | python3 -c '
import json,sys
for n in json.load(sys.stdin)["items"]:
    name = n["metadata"]["name"]
    ready = next((c["status"] for c in n["status"]["conditions"] if c["type"] == "Ready"), "Unknown")
    if n["spec"].get("unschedulable"): print(f"{name} (cordoned)")
    elif ready != "True":              print(f"{name} (Ready={ready})")
')"
  [ -z "$not_ok" ] || die "not rebalancing, these nodes cannot take pods: ${not_ok//$'\n'/, }. Wait for them to
come back, or uncordon them, then re-run: make rebalance-workloads"
  node_count="$(printf '%s' "$nodes_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')"
  [ "$node_count" -eq "${#ALL_HOSTS[@]}" ] \
    || die "the cluster has ${node_count} nodes and inventory.yaml expects ${#ALL_HOSTS[@]}. A rebalance now would skew the spread"
  ok "all ${node_count} nodes Ready and schedulable"
}

pods_per_node() {
  kubectl get pods -A --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/   /'
}

# Tests for a PVC, not a name, because operator-generated names change.
select_deployments() {
  SELECTION="$(kubectl get deploy -A -o json | SKIP_NS="$SKIP_NAMESPACES" PVC_NS="$PVC_NAMESPACES" python3 -c '
import json,os,sys
skip_ns = set(os.environ["SKIP_NS"].split())
pvc_ns  = set(os.environ["PVC_NS"].split())
for d in json.load(sys.stdin)["items"]:
    ns, name = d["metadata"]["namespace"], d["metadata"]["name"]
    spec = d["spec"]
    pvcs = [v for v in (spec["template"]["spec"].get("volumes") or []) if "persistentVolumeClaim" in v]
    rolling = spec.get("strategy", {}).get("type", "RollingUpdate") == "RollingUpdate"
    if   ns in skip_ns:              verdict = "SKIP\tnamespace in SKIP_NAMESPACES"
    elif pvcs and ns not in pvc_ns:  verdict = "SKIP\tmounts a PVC (add ns to REBALANCE_PVC_NAMESPACES to move it)"
    elif pvcs and rolling:           verdict = "SKIP\tmounts a PVC and rolls: maxSurge wants the volume on two nodes at once"
    elif not spec.get("replicas"):   verdict = "SKIP\tscaled to 0"
    else:                            verdict = "DO\t"
    print(f"{verdict}\t{ns}\t{name}")
')" || die "could not list deployments"
  printf '%s\n' "$SELECTION" | grep -q . || die "no deployments found. Is this the right cluster?"
  say "skipping"
  printf '%s\n' "$SELECTION" | awk -F'\t' '$1=="SKIP"{printf "   %s/%s  (%s)\n", $3, $4, $2}'
}

# Runs in the background, so it reports through its exit code. ok and bad in a subshell miss the summary.
restart_one() {
  kubectl -n "$1" rollout restart "deployment/$2" > /dev/null 2>&1 || return 1
  kubectl -n "$1" rollout status "deployment/$2" --timeout="${ROLLOUT_TIMEOUT}s" > /dev/null 2>&1 || return 2
}

wait_batch() {
  local i ns name
  for i in "${!BATCH_PIDS[@]}"; do
    IFS=$'\t' read -r ns name <<< "${BATCH_NAMES[$i]}"
    wait "${BATCH_PIDS[$i]}"
    case $? in
      0) ok "${ns}/${name}" ;;
      1) bad "${ns}/${name} (restart not accepted)" ;;
      *) bad "${ns}/${name} (not Available within ${ROLLOUT_TIMEOUT}s. Check: kubectl -n ${ns} describe deploy ${name})" ;;
    esac
  done
  BATCH_PIDS=()
  BATCH_NAMES=()
}

restart_deployments() {
  local targets ns name
  targets="$(printf '%s\n' "$SELECTION" | awk -F'\t' '$1=="DO"{print $3"\t"$4}')"
  say "restarting $(printf '%s\n' "$targets" | grep -c .) deployments, ${PARALLEL} at a time"
  while IFS=$'\t' read -r ns name; do
    [ -n "$ns" ] || continue
    restart_one "$ns" "$name" &
    BATCH_PIDS+=("$!")
    BATCH_NAMES+=("${ns}"$'\t'"${name}")
    [ "${#BATCH_PIDS[@]}" -lt "$PARALLEL" ] || wait_batch
  done <<< "$targets"
  wait_batch
}

# ---- main ----

require kubectl
use_kubeconfig
assert_api
assert_all_nodes_schedulable

say "pod spread before"
pods_per_node

select_deployments
restart_deployments

say "pod spread after"
pods_per_node

summary || exit 1
