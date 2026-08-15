#!/usr/bin/env bash
#
# Shared helpers for every bootstrap script here. Source it near the top: it self-locates the repo root, loads
# versions.env then the gitignored .env, parses the gitignored inventory.yaml into the node arrays every script
# iterates, and derives what a flat file cannot hold (paths, the Talos version).
# It sets no shell options; each script keeps its own `set` line.

[[ -n "${_COMMON_SH:-}" ]] && return
_COMMON_SH=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Sourced FIRST: the derived block below reads it. die() is not defined yet, so error raw.
VERSIONS_FILE="${REPO_ROOT}/versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
  printf '\033[1;31mERROR: missing %s (committed recipe; it should be in the repo checkout)\033[0m\n' \
    "$VERSIONS_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

ENV_FILE="${REPO_ROOT}/.env"
if [ ! -f "$ENV_FILE" ]; then
  printf '\033[1;31mERROR: missing %s\n       copy the template and edit it:  cp .env.example .env\033[0m\n' \
    "$ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# Scripts run under `set -u`, so default every key here: an older .env missing one must not trip it.
# Empty means "skip the feature it enables", see each key's comment in .env.example.
: "${GITHUB_GHCR_PULL_TOKEN_SECRET:=}"    # 03c bakes into node machine config (kubelet pulls private ghcr.io)
: "${DISABLE_FLANNEL_AND_KUBE_PROXY:=true}"   # defaults to no CNI and no kube-proxy, for a cluster installing its own
: "${PRE_DRAIN_HEALTH_HOOK:=}"            # 03e runs it before draining each node; empty = nothing gates store health
: "${REBALANCE_SKIP_NAMESPACES:=}"        # 03g leaves these namespaces alone; empty = restart every stateless Deployment

# Pinned by the hardware, not per-deployment, so not in .env.
EXPECT_NIC="end0"          # Pi 5 wired NIC (the VIP binds to it)
API_PORT=50000            # Talos API port
GHCR_SERVER="ghcr.io"     # registry the GHCR pull token is scoped to
TALOS_IMAGE_REPO="ghcr.io/yama6a/talos-raspberry-pi5"        # the Pi 5 Talos image; TALOS_IMAGE_RELEASE pins the tag
FACTORY_HOST="factory.talos.dev"                             # stock images for node types we don't build (x86)

# Cannot live in a flat .env: interpolation and a derived version.
IFACE="${EXPECT_NIC}"                           # wired NIC the VIP binds to (dhcp + vip)
# The image release tag is `<talos version>-<build revision>`; everything Talos-side wants just the version.
TALOS_VERSION="${TALOS_IMAGE_RELEASE%-*}"
TALOSCTL_VERSION="${TALOS_VERSION}"             # talosctl container (talosctl() below; boot-verify)
IMAGE_CACHE="${REPO_ROOT}/.cache/images"        # 03a downloads each node type's raw image here (gitignored)

say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }

PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
# Returns non-zero if anything failed, so a caller can `summary || exit 1`.
summary() {
  printf '\n=============== summary: %d passed, %d failed ===============\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

require() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null && continue
    case "$t" in
      kubectl)  die "kubectl not found on PATH, install it (https://kubernetes.io/docs/tasks/tools/)" ;;
      yq)       die "yq not found on PATH, install it (https://github.com/mikefarah/yq, brew install yq)" ;;
      docker)   die "docker not found on PATH (and it needs host networking enabled)" ;;
      *)        die "$t not found on PATH" ;;
    esac
  done
}

# ---- CNI ----
# One switch drives both keys because they are not independent: Flannel does not replace kube-proxy, so a
# `flannel` + `proxy.disabled: true` combination boots to a healthy-looking cluster where no ClusterIP works.
case "$DISABLE_FLANNEL_AND_KUBE_PROXY" in
  true)  CNI_NAME="none"    ; PROXY_DISABLED="true"  ;;
  false) CNI_NAME="flannel" ; PROXY_DISABLED="false" ;;
  *) die "DISABLE_FLANNEL_AND_KUBE_PROXY must be true or false, got '${DISABLE_FLANNEL_AND_KUBE_PROXY}'" ;;
esac

# ---- the node inventory ----
# Parsed below require()/die() rather than with the other derived values, because it needs both. A malformed
# inventory therefore fails at the top of EVERY script, not halfway into whichever one first reads a field.
INVENTORY="${REPO_ROOT}/inventory.yaml"
[ -f "$INVENTORY" ] || die "missing ${INVENTORY}
       copy the template and edit it:  cp inventory.example.yaml inventory.yaml"
# A leftover CLUSTER_NODES is no longer read as an array, so \${#CLUSTER_NODES[@]} would quietly be 1 and the
# node-count gates would compare against the wrong number. Fail instead of being subtly wrong.
[ -z "${CLUSTER_NODES:-}" ] || die "CLUSTER_NODES is still set in .env; the node list moved to inventory.yaml. Delete that line."
require yq

declare -A NODE_IP NODE_ROLE NODE_TYPE NODE_IMAGE_SOURCE NODE_IMAGE_FILE NODE_IMAGE_SCHEMATIC NODE_INSTALL_DISK
ALL_HOSTS=(); ALL_IPS=()          # every node, in inventory order
CP_HOSTS=();  CP_IPS=()           # role controlplane: these carry the VIP, etcd and the apiserver certSANs
WORKER_HOSTS=(); WORKER_IPS=()    # role worker
# No hardware-specific subsets here on purpose: 03b and 03d each filter on NODE_TYPE themselves, next to the
# checks and the config that are specific to that hardware. This file stays inventory data, not policy.

# ONE yq call for the whole file, so sourcing costs a single subprocess however many nodes there are.
# Joined on '|' and NOT @tsv: tab is an IFS whitespace character, so `read` collapses a run of them and the
# optional imageSchematic would silently shift every later field one to the left.
while IFS='|' read -r _h _ip _role _type _src _file _sch _disk; do
  [ -n "$_h" ] || continue
  for _f in ip:"$_ip" role:"$_role" type:"$_type" imageSource:"$_src" imageFile:"$_file" installDisk:"$_disk"; do
    [ -n "${_f#*:}" ] || die "inventory: node '${_h}' is missing ${_f%%:*}"
  done
  case "$_role" in controlplane|worker) ;; *) die "inventory: node '${_h}' has role '${_role}', want controlplane or worker" ;; esac
  # Both directions, so imageSource and imageSchematic cannot quietly disagree: a missing schematic would send
  # the factory a 404, and a stray one on a release node would be read by nothing.
  case "$_src" in
    github-release) [ -z "$_sch" ] || die "inventory: node '${_h}' is imageSource github-release, so drop its imageSchematic; nothing reads it" ;;
    image-factory)  [ -n "$_sch" ] || die "inventory: node '${_h}' is imageSource image-factory, so it needs an imageSchematic" ;;
    *) die "inventory: node '${_h}' has imageSource '${_src}', want github-release or image-factory" ;;
  esac
  case "$_disk" in /dev/?*) ;; *) die "inventory: node '${_h}' has installDisk '${_disk}', want a whole-device path like /dev/nvme0n1 or /dev/sda" ;; esac
  [ -z "${NODE_IP[$_h]:-}" ] || die "inventory: '${_h}' appears twice"
  NODE_IP[$_h]="$_ip"; NODE_ROLE[$_h]="$_role"; NODE_TYPE[$_h]="$_type"
  NODE_IMAGE_SOURCE[$_h]="$_src"; NODE_IMAGE_FILE[$_h]="$_file"; NODE_IMAGE_SCHEMATIC[$_h]="$_sch"
  NODE_INSTALL_DISK[$_h]="$_disk"
  ALL_HOSTS+=("$_h"); ALL_IPS+=("$_ip")
  if [ "$_role" = controlplane ]; then CP_HOSTS+=("$_h"); CP_IPS+=("$_ip")
  else                                 WORKER_HOSTS+=("$_h"); WORKER_IPS+=("$_ip"); fi
done < <(yq -r '.nodes[] | [.host, .ip, .role, .type, .imageSource, .imageFile, (.imageSchematic // ""), (.installDisk // "")] | join("|")' "$INVENTORY")

[ "${#CP_HOSTS[@]}" -gt 0 ] || die "inventory: no node has role controlplane, so there is no cluster to build"
[ "$(printf '%s\n' "${ALL_IPS[@]}" | sort -u | grep -c .)" -eq "${#ALL_IPS[@]}" ] \
  || die "inventory: two nodes share an IP"

# The installer image `talosctl upgrade` writes to a node. The ONE place the two image sources are resolved,
# so the flasher and the upgrade cannot disagree about where a node's bits come from.
installer_ref_for() {
  local h="$1"
  case "${NODE_IMAGE_SOURCE[$h]:-}" in
    github-release) printf '%s:%s\n' "$TALOS_IMAGE_REPO" "$TALOS_IMAGE_RELEASE" ;;
    image-factory)  printf '%s/metal-installer/%s:%s\n' "$FACTORY_HOST" "$(factory_schematic_id "${NODE_IMAGE_SCHEMATIC[$h]}")" "$TALOS_VERSION" ;;
    *) die "unknown node '${h}': inventory.yaml has ${ALL_HOSTS[*]}" ;;
  esac
}

# POSTs the extension set and gets back the id that addresses both the raw image and the installer built from
# it. Idempotent server-side, so there is no id to pin and none to go stale.
_SCHEMATIC_ID=""
factory_schematic_id() {
  [ -n "$_SCHEMATIC_ID" ] && { printf '%s\n' "$_SCHEMATIC_ID"; return 0; }
  local f="${REPO_ROOT}/${1}"
  [ -f "$f" ] || die "missing schematic ${f} (inventory points at it)"
  require curl
  _SCHEMATIC_ID="$(curl -fsS -X POST --data-binary "@${f}" "https://${FACTORY_HOST}/schematics" \
                   | yq -r '.id // ""')" || die "could not reach https://${FACTORY_HOST}/schematics"
  [ -n "$_SCHEMATIC_ID" ] || die "${FACTORY_HOST} returned no schematic id for ${f}"
  printf '%s\n' "$_SCHEMATIC_ID"
}

# Accepts both spellings because callers pass `true` and `1` about evenly. A gate that recognised only one
# would prompt in an unattended run, and an orchestrator with no stdin reads that as an abort.
assume_yes() { case "${ASSUME_YES:-}" in true|1|yes|YES) return 0 ;; *) return 1 ;; esac; }

confirm() {
  assume_yes && return 0
  local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]
}

# Destructive-action gate: make the operator type a word, because y is too easy to hit by reflex. Both return
# non-zero on a mismatch so the caller picks its own abort message and exit code.
#   confirm_word        <WORD> <prompt>  honours ASSUME_YES, for steps an orchestrator drives unattended
#   confirm_word_always <WORD> <prompt>  ignores it, for the gates that wipe the cluster. An ASSUME_YES left
#                                        over from an earlier command must never be able to skip those.
_ask_word() { local a; read -r -p ">> ${2:+$2 }type $1 to proceed: " a; [ "$a" = "$1" ]; }
confirm_word()        { assume_yes && return 0; _ask_word "$@"; }
confirm_word_always() { _ask_word "$@"; }

CLUSTER_DIR="${REPO_ROOT}/secrets"   # the only real talosconfig + kubeconfig; a symlink to an off-repo store

use_kubeconfig() {
  export KUBECONFIG="${CLUSTER_DIR}/kubeconfig"   # the 03c kubeconfig (points at the VIP)
  [ -f "$KUBECONFIG" ] || die "missing ${KUBECONFIG}, run step 03 (03c) first"
}
assert_api() { kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG}"; }

# Dockerized because the macOS talosctl build is unreliable here.
# TALOS_SCRATCH (optional): a host temp dir mounted at /scratch for throwaway render files that must be
# container-visible but must NOT persist in the durable secrets dir. Unset means not mounted.
talosctl() {
  docker run --rm -i --network host \
    -v "${CLUSTER_DIR}:/work" -w /work \
    ${TALOS_SCRATCH:+-v "${TALOS_SCRATCH}:/scratch"} \
    -e TALOSCONFIG=/work/talosconfig \
    "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

# wait_talos_api <ip> <timeout-secs> <secure|insecure> [poll-secs]: block until the node's Talos API answers,
# printing a dot per attempt. Returns non-zero on timeout instead of dying, so each caller writes its own
# diagnosis: "not in maintenance" and "never came back" are the same wait but very different advice.
# insecure = maintenance mode, no talosconfig needed. nc gates the call because talosctl against a down node
# blocks for its own timeout, which stalls the dots and makes the wait look hung.
wait_talos_api() {
  local ip="$1" secs="$2" mode="$3" poll="${4:-5}" deadline
  local args=(-e "$ip" -n "$ip" version)
  case "$mode" in
    insecure) args+=(--insecure) ;;
    secure)   ;;
    *) die "wait_talos_api: mode is '${mode}', want secure or insecure" ;;
  esac
  deadline=$(( $(date +%s) + secs ))
  until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl "${args[@]}" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    printf '.'; sleep "$poll"
  done
}

# The caller sets STEP=0 and STEP_TOTAL=<n> once; every step goes through step()/run_step(), so adding or
# removing a step only changes STEP_TOTAL, never a hand-written number.
step() { STEP=$((STEP+1)); say "STEP ${STEP}/${STEP_TOTAL}, $*"; }

# run_step <label> <dir> <script> [best-effort] [hint]: runs <dir>/<script> in a subshell with stdin detached,
# then dies (default) or warns and returns 1 (best-effort). The 5th arg overrides the recovery hint.
run_step() {
  local label="$1" dir="$2" script="$3" mode="${4:-fatal}" hint="${5:-}"
  step "${script} (${label})"
  if ( cd "$dir" && bash "./$script" </dev/null ); then ok "${script} done"; return 0; fi
  if [ "$mode" = best-effort ]; then
    warn "${hint:-${script} did not complete; re-run it by hand + commit/push if needed}"
    return 1
  fi
  die "${hint:-${script} failed, fix and resume from ${script%.sh} by hand}"
}
