#!/usr/bin/env bash
# Rolling-restarts the stateless Deployments so the scheduler re-spreads them after 03e's node-by-node drain.
# A nudge, not guaranteed balance: the scheduler scores each pod alone. Not needed after 03f, which moves no pods.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
# Which namespaces must not be restarted depends on what the cluster runs, not on the hardware, so the list
# comes from .env. Typically the CSI driver's namespace (its sidecars may be mid-volume-op) and the ingress
# data plane.
SKIP_NAMESPACES="$REBALANCE_SKIP_NAMESPACES"
# A PVC alone does not make a Deployment unmovable: with `Recreate` the old pod releases the volume before the
# new one wants it. Opting a namespace in here says its volumes can follow the pod. `RollingUpdate` is still
# skipped even here, see select_deployments.
PVC_NAMESPACES="$REBALANCE_PVC_NAMESPACES"
ROLLOUT_TIMEOUT=300   # secs per Deployment; restarts are serial, maxSurge doubles pods and 3 Pi 5s are RAM-tight

# ---- state ----
SELECTION=""   # set by select_deployments: "DO|SKIP<TAB>reason<TAB>ns<TAB>name" per line

# ---- functions ----

# Restarting onto a shrunken cluster would just pack the survivors.
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
come back (or uncordon), then re-run: make rebalance-workloads"
  node_count="$(printf '%s' "$nodes_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')"
  [ "$node_count" -eq "${#ALL_HOSTS[@]}" ] \
    || die "cluster has ${node_count} nodes, inventory.yaml expects ${#ALL_HOSTS[@]}; rebalancing now would skew the spread"
  ok "all ${node_count} nodes Ready and schedulable"
}

pods_per_node() {
  kubectl get pods -A --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/   /'
}

# Statelessness is tested by looking for a PVC, not by name: operator-generated names (vmsingle-<cr>) rot.
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
  printf '%s\n' "$SELECTION" | grep -q . || die "no deployments found, is this the right cluster?"
  say "skipping"
  printf '%s\n' "$SELECTION" | awk -F'\t' '$1=="SKIP"{printf "   %s/%s  (%s)\n", $3, $4, $2}'
}

restart_deployments() {
  local targets ns name
  targets="$(printf '%s\n' "$SELECTION" | awk -F'\t' '$1=="DO"{print $3"\t"$4}')"
  say "restarting $(printf '%s\n' "$targets" | grep -c .) deployments, one at a time"
  while IFS=$'\t' read -r ns name; do
    [ -n "$ns" ] || continue
    if ! kubectl -n "$ns" rollout restart "deployment/${name}" >/dev/null 2>&1; then
      bad "${ns}/${name} (restart not accepted)"; continue
    fi
    if kubectl -n "$ns" rollout status "deployment/${name}" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null 2>&1; then
      ok "${ns}/${name}"
    else
      bad "${ns}/${name} (not Available within ${ROLLOUT_TIMEOUT}s, check: kubectl -n ${ns} describe deploy ${name})"
    fi
  done <<< "$targets"
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
