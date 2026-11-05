#!/usr/bin/env bash
# Makes the taints on every node match inventory.yaml. It touches only taints that this repo set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

use_kubeconfig
assert_api
for host in "${ALL_HOSTS[@]}"; do sync_node_taints "$host"; done
