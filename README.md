# talos-raspberry-pi5-cluster

**Turns bare Raspberry Pi 5s into a running [Talos Linux](https://www.talos.dev/) Kubernetes cluster.**

![Talos](https://img.shields.io/badge/Talos-Linux-ff7300)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326ce5?logo=kubernetes&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Last commit](https://img.shields.io/github/last-commit/yama6a/talos-raspberry-pi5-cluster)

<p align="center">
  <img src="docs/images/rackmount_0.jpeg" alt="The assembled 3-node Raspberry Pi 5 cluster in a 10-inch rack" width="600">
</p>

- Hardware, OS and cluster bring-up: flash the NVMe drives, configure Talos, bootstrap etcd, hand over a
  `kubeconfig`.
- It stops there. Nothing that runs on the cluster lives here.
- The node image is built in [talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5). This repo
  consumes its releases.

## Contents

- [Overview](#overview)
- [Hardware](#hardware)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Where this repo stops](#where-this-repo-stops)
- [Day-2 operations](#day-2-operations)
- [Documentation](#documentation)
- [Contributing](CONTRIBUTING.md)
- [License](#license) and [Credits](#credits)

## Overview

- Three Raspberry Pi 5 boards, every one a control-plane node. etcd runs on all three, and workloads share the
  same nodes.
- Talos boots from NVMe. Talos ships no Pi 5 image, so the nodes run a release of
  [talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5). It has a Raspberry Pi kernel with 4K
  pages, plus the extensions the cluster needs.
- A 4th bay takes a worker, and it does not have to be a Pi. Each node in `inventory.yaml` names its hardware
  type, and the scripts pick its image from that.
- One Kubernetes object is applied from here: the `nic-keeper` DaemonSet. It is the runtime half of the Pi 5 NIC
  fix, and `03d` applies it.

Config lives in three files. No script hardcodes a value.

| File | Committed | Holds |
|---|---|---|
| `versions.env` | yes | the Talos image release and the Kubernetes version. Renovate bumps both |
| `inventory.yaml` | no, copy `inventory.example.yaml` | one entry per node: role, hardware type, image source |
| `.env` | no, copy `.env.example` | cluster name, VIP, sizing, hooks, registry auth |

## Hardware

Three Raspberry Pi 5 (8 GB) boards in a 10-inch 2U rack, booting from NVMe. Parts and reasons are in
[docs/01_hardware.md](docs/01_hardware.md).

| Component    | Choice                                       | Qty                  |
|--------------|----------------------------------------------|----------------------|
| SBC          | Raspberry Pi 5, 8 GB                         | 3                    |
| Rack         | GeeekPi DP-0046 (10" 2U)                     | 1                    |
| NVMe carrier | 52Pi RS-P11 boards                           | 4 (1 unused for now) |
| SSD          | Crucial P310 1 TB (CT1000P310SSD8, ~220 TBW) | 3                    |
| Power        | 27 W USB-C PD (5.1 V / 5 A)                  | 3                    |
| Cooling      | Pi 5 active cooler + aluminum heat sink      | 3                    |

## Repository layout

```
.
|-- Makefile                # thin dispatcher over lib/shell. Run `make help`
|-- versions.env            # committed: the Talos and Kubernetes pins, bumped by Renovate
|-- inventory.example.yaml  # template for the node list. Copy to inventory.yaml
|-- .env.example            # template for config and secrets. Copy to .env
|-- docs/                   # decision docs (01 to 06)
|   `-- runbooks/           # the procedures, one per decision doc
|-- lib/
|   |-- shell/              # every bootstrap script and the shared common.sh
|   |-- k8s/                # the nic-keeper manifest, applied by 03d
|   `-- talos/              # Image Factory schematics for node types without a custom build
`-- secrets/                # gitignored: Talos PKI, talosconfig, kubeconfig. A symlink to an off-repo store
```

## Getting started

Tested only on macOS. Linux or WSL may need changes.

You need `docker` with host networking, `git`, `kubectl` and `yq`. `talosctl` runs in Docker through
`make talosctl`, because the macOS build is unreliable.

```bash
# 1. Build the EEPROM card, then boot each Pi from it once (docs/runbooks/02_raspi_eeprom.md)
make build-eeprom-card

# 2. Configure
cp inventory.example.yaml inventory.yaml   # one entry per node
cp .env.example .env                       # cluster name, VIP, sizing, GHCR auth

# 3. Flash each NVMe over a USB adapter, then boot the nodes into maintenance mode
make flash-talos-nvme                      # once per drive
make verify-talos-boot

# 4. Bring up the cluster: boot check, config, etcd, NIC hardening
make bootstrap-cluster

# 5. Verify and take the kubeconfig
make check-health
make merge-kubeconfig                      # merges into ~/.kube/config and makes it the active context
kubectl get nodes                          # all present, NotReady until a CNI is installed
```

Each step, with its checks and failure modes, is in [docs/runbooks/](docs/runbooks/). `make help` lists every
target, and each target runs one script in `lib/shell/`.

## Where this repo stops

- `make bootstrap-cluster` ends with a configured cluster, etcd bootstrapped, and a `kubeconfig` in `secrets/`.
- By default the nodes stay `NotReady`. No CNI is installed, and installing one is the first job of whatever runs
  on the cluster next.
- `DISABLE_FLANNEL_AND_KUBE_PROXY="false"` in `.env` keeps Talos' built-in Flannel and kube-proxy instead. The
  cluster then reaches `Ready` alone, with pod and service networking only: no LoadBalancer, no gateway. Decide
  before bootstrap. Switching later means a rebuild.
- `make merge-kubeconfig` is the handover. Nothing else in `secrets/` leaves this repo.
  `eval "$(make print-kubeconfig)"` points one shell at the cluster and leaves `~/.kube/config` alone.

This repo cannot know what the cluster runs. These optional `.env` keys let the workloads take part in node
lifecycle:

| Key | Used by | If empty |
|---|---|---|
| `PRE_DRAIN_HEALTH_HOOK` | `03e`, before draining each node | nothing checks replicated stores before a reboot. `03e` warns |
| `PRE_DRAIN_EVACUATE_HOOK` | `03e`, once per node after that check | nothing moves off the node before the drain |
| `FORCE_DELETE_SKIP` | `03e`, when a graceful drain times out | the force-delete kills every pod on the node |
| `REBALANCE_SKIP_NAMESPACES` | `03g` | every stateless Deployment is restarted |
| `REBALANCE_PVC_NAMESPACES` | `03g` | a Deployment that mounts a PVC is never restarted |

## Day-2 operations

| Task                      | Command                                                                       |
|---------------------------|-------------------------------------------------------------------------------|
| Upgrade Talos             | `make upgrade-talos`                                                          |
| Upgrade Kubernetes        | `make upgrade-k8s`                                                            |
| Change machine config     | `make reapply-talos-config [NODE=<host>]`                                     |
| Add a node                | `make add-node NODE=<host>`                                                   |
| Recover a lost node       | `make recover-node NODE=<host>`                                               |
| Re-spread stateless pods  | `make rebalance-workloads`                                                    |
| Reset all nodes           | `make reset-cluster`                                                          |
| Point kubectl at it       | `make merge-kubeconfig`, or `eval "$(make print-kubeconfig)"` for one shell   |
| Inspect                   | `make check-health`, `make talosctl <args>`                                   |

A Talos or Kubernetes bump takes two steps. Merge the Renovate PR that moves the pin in `versions.env`, then run
the upgrade target. Merging alone changes nothing on the nodes.

## Documentation

Each decision doc has a runbook with the same name in [docs/runbooks/](docs/runbooks/).

| Doc                                                | Covers                                                                          |
|----------------------------------------------------|---------------------------------------------------------------------------------|
| [01_hardware](docs/01_hardware.md)                 | The parts and why each was picked.                                              |
| [02_raspi_eeprom](docs/02_raspi_eeprom.md)         | The Pi 5 EEPROM boot settings.                                                  |
| [03_operating_system](docs/03_operating_system.md) | Talos, the Pi 5 image, the cluster config, upgrades, NIC hardening.             |
| [04_worker_nodes](docs/04_worker_nodes.md)         | The node inventory, and a worker that does not have to be a Pi.                 |
| [05_node_recovery](docs/05_node_recovery.md)       | What a lost or replaced node costs, and what heals by itself.                   |
| [06_renovate](docs/06_renovate.md)                 | Automated dependency updates, and what merges without review.                   |

Repo-wide conventions are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

- Talos Linux by [Sidero Labs](https://www.siderolabs.com/).
- The Pi 5 node image comes from [yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5),
  which credits its own upstreams.

## License

MIT. See [LICENSE](LICENSE).
