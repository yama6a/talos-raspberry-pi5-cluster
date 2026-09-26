# Dispatches to lib/shell and holds no logic, versions or values. `make init-talos` equals running 03c by hand.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster lifecycle  (destructive, each asks for a typed confirmation)
.PHONY: bootstrap-cluster
bootstrap-cluster: ## DANGER: first bring-up of freshly flashed nodes, to a configured cluster and a kubeconfig. Archives old creds.
	bash lib/shell/DANGEROUS_bootstrap_cluster.sh

.PHONY: reset-cluster
reset-cluster: ## DANGER: wipe every node (STATE, EPHEMERAL, the storage volume) back to maintenance mode.
	bash lib/shell/DANGEROUS_reset_talos_cluster.sh

##@ Node image and Talos bring-up  (steps 02 and 03, Talos tooling runs in Docker)
.PHONY: build-eeprom-card
build-eeprom-card: ## 02: build a reusable SD card that flashes the Pi 5 EEPROM boot order and PCIe probe.
	bash lib/shell/02_raspi_eeprom.sh

.PHONY: flash-talos-nvme
flash-talos-nvme: ## 03a: download a node's Talos image and write it to an NVMe over USB. NODE=<hostname> picks the image, or choose from a list.
	bash lib/shell/03a_talos_image_flasher.sh $(NODE)

.PHONY: verify-talos-boot
verify-talos-boot: ## 03b: check that every freshly flashed node booted into maintenance mode.
	bash lib/shell/03b_talos_boot_verify.sh

.PHONY: init-talos
init-talos: ## 03c: first bring-up. Every node in maintenance mode. Applies config, bootstraps etcd, writes kubeconfig and talosconfig.
	bash lib/shell/03c_talos_cluster_config.sh

.PHONY: add-node
add-node: ## 03c: join one node from maintenance mode into the running cluster, with no etcd bootstrap. NODE=<hostname>.
	@test -n "$(NODE)" || { echo "usage: make add-node NODE=talos-w1   (hostnames come from inventory.yaml)"; exit 1; }
	bash lib/shell/03c_talos_cluster_config.sh $(NODE)

.PHONY: reapply-talos-config
reapply-talos-config: ## 03c: push a changed machine config to running nodes, after a dry run and a confirm. NODE=<hostname> for one, omit for all.
	bash lib/shell/03c_talos_cluster_config.sh --reapply $(NODE)

.PHONY: harden-nics
harden-nics: ## 03d: harden the Pi 5 NICs: machine config for offloads, rings and watchdog, plus the nic-keeper DaemonSet.
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
recover-node: ## 05: rejoin one wiped or replaced node and fix what does not heal by itself. NODE=<hostname>, YES=1 skips the prompt.
	@test -n "$(NODE)" || { echo "usage: make recover-node NODE=talos-cp3 [YES=1]"; exit 1; }
	bash lib/shell/recover_node.sh $(NODE) $(if $(YES),--yes,)

##@ Kubeconfig  (point kubectl at the cluster. merge-kubeconfig is the handover out of this repo)
.PHONY: merge-kubeconfig
merge-kubeconfig: ## Merge the 03c kubeconfig into ~/.kube/config and make it the active context. Backs up the old file first.
	bash lib/shell/merge_kubeconfig.sh

.PHONY: print-kubeconfig
print-kubeconfig: ## Print an export line that points one shell at the cluster and leaves ~/.kube/config alone.
	@bash -c 'source lib/shell/common.sh && echo "export KUBECONFIG=$$CLUSTER_DIR/kubeconfig"'

##@ Health and inspection  (read-only, through the dockerized talosctl)
.PHONY: check-health
check-health: ## Wait for and report Talos cluster health.
	@bash -c 'source lib/shell/common.sh && talosctl health'

.PHONY: talosctl
talosctl: ## Run dockerized talosctl, e.g. `make talosctl get members`. A flag needs `--` first: `make talosctl -- -n <ip> etcd members`.
	@bash -c 'source lib/shell/common.sh && talosctl $(filter-out $@,$(MAKECMDGOALS))'

# Swallows the words after `make talosctl` as no-op goals, so talosctl gets them. A mistyped target no-ops too.
# Flags need `--` first: without it Make reads `-n` as its own --just-print and runs nothing.
%:
	@:
