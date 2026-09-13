# A thin dispatcher over the numbered runbook scripts. Holds NO logic, versions or values: every target just
# runs the step script it names, so `make init-talos` and running lib/shell/03c_talos_cluster_config.sh by
# hand are identical. `make help` lists everything. The health targets need a live cluster and a populated
# .env. This repo stops at a configured cluster and a kubeconfig; nothing that runs ON it lives here.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster lifecycle  (DANGEROUS: destructive; each prompts for a typed confirmation)
.PHONY: bootstrap-cluster
bootstrap-cluster: ## DANGER: first-time init of freshly-flashed nodes -> configured cluster + kubeconfig (archives old creds).
	bash lib/shell/DANGEROUS_bootstrap_cluster.sh

.PHONY: reset-cluster
reset-cluster: ## DANGER: wipe all nodes (STATE + EPHEMERAL + the storage volume) back to maintenance.
	bash lib/shell/DANGEROUS_reset_talos_cluster.sh

##@ Node image & Talos bring-up  (step 02-03; the talos steps run their tooling in Docker)
.PHONY: build-eeprom-card
build-eeprom-card: ## 02: build a reusable SD card that flashes the Pi 5 EEPROM (boot order / PCIe probe).
	bash lib/shell/02_raspi_eeprom.sh

.PHONY: flash-talos-nvme
flash-talos-nvme: ## 03a: download a node's Talos image and write it to an NVMe SSD over USB. NODE=<hostname> picks which image; omit it to choose from a list.
	bash lib/shell/03a_talos_image_flasher.sh $(NODE)

.PHONY: verify-talos-boot
verify-talos-boot: ## 03b: verify freshly-flashed nodes boot into maintenance mode (the inventory's bootVerify nodes).
	bash lib/shell/03b_talos_boot_verify.sh

.PHONY: init-talos
init-talos: ## 03c: FIRST bring-up. Needs EVERY node in maintenance (fresh flash, or after reset-cluster): applies config, bootstraps etcd, writes kube/talosconfig.
	bash lib/shell/03c_talos_cluster_config.sh

.PHONY: add-node
add-node: ## 03c: configure and join ONE node from maintenance into the RUNNING cluster (control-plane or worker), no etcd bootstrap. NODE=<hostname>.
	@test -n "$(NODE)" || { echo "usage: make add-node NODE=talos-w1   (hostnames come from inventory.yaml)"; exit 1; }
	bash lib/shell/03c_talos_cluster_config.sh $(NODE)

.PHONY: reapply-talos-config
reapply-talos-config: ## 03c: push a changed machine config to nodes that are already RUNNING (dry-run + confirm first). NODE=<hostname> for one, omit for all.
	bash lib/shell/03c_talos_cluster_config.sh --reapply $(NODE)

.PHONY: harden-nics
harden-nics: ## 03d: NIC hardening for every node: machine config (offloads/rings/watchdog) + the nic-keeper DaemonSet.
	bash lib/shell/03d_nic_hardening.sh

.PHONY: upgrade-talos
upgrade-talos: ## 03e: rolling in-place upgrade of the Talos OS to the pinned installer image.
	bash lib/shell/03e_talos_upgrade.sh

.PHONY: upgrade-k8s
upgrade-k8s: ## 03f: rolling in-place upgrade of Kubernetes to the pinned version.
	bash lib/shell/03f_k8s_upgrade.sh

.PHONY: rebalance-workloads
rebalance-workloads: ## 03g: rolling-restart the stateless Deployments so the scheduler re-spreads them (03e runs this).
	bash lib/shell/03g_rebalance_workloads.sh

.PHONY: recover-node
recover-node: ## 05: rejoin ONE wiped/replaced node and fix what does not self-heal. NODE=<hostname>, add YES=1 to skip the prompt.
	@test -n "$(NODE)" || { echo "usage: make recover-node NODE=talos-cp3 [YES=1]"; exit 1; }
	bash lib/shell/recover_node.sh $(NODE) $(if $(YES),--yes,)

##@ Kubeconfig  (point your kubectl at the cluster; merge-kubeconfig is the handover out of this repo)
.PHONY: merge-kubeconfig
merge-kubeconfig: ## Merge the 03c kubeconfig into ~/.kube/config and make it the active context (timestamped backup).
	bash lib/shell/merge_kubeconfig.sh

.PHONY: print-kubeconfig
print-kubeconfig: ## Print the 03c kubeconfig export line, for pointing ONE shell at the cluster without touching ~/.kube/config.
	@bash -c 'source lib/shell/common.sh && echo "export KUBECONFIG=$$CLUSTER_DIR/kubeconfig"'

##@ Health & inspection  (read-only; use the dockerized talosctl + the 03c kubeconfig)
.PHONY: check-health
check-health: ## Talos: wait for and report overall cluster health.
	@bash -c 'source lib/shell/common.sh && talosctl health'

.PHONY: talosctl
talosctl: ## Run dockerized talosctl, e.g. `make talosctl get members`. Any FLAG needs a `--` first: `make talosctl -- -n <ip> etcd members`.
	@bash -c 'source lib/shell/common.sh && talosctl $(filter-out $@,$(MAKECMDGOALS))'

# Words after `make talosctl ...` (get, members, services, ...) are extra goals to Make; this no-op catch-all
# swallows them so they're passed to talosctl instead of erroring. Explicit targets above still take priority,
# so a mistyped real target quietly no-ops rather than erroring, the one cost of positional passthrough args.
#
# A flag never reaches talosctl on its own: Make claims it first, and `-n` is Make's own --just-print, so
# `make talosctl -n <ip> etcd members` silently prints the command instead of running it. Put a `--` before
# the first flag and Make stops parsing options: `make talosctl -- -n <ip> etcd members`.
%:
	@:
