# talos-raspberry-pi5-cluster

**Turns bare Raspberry Pi 5s into a running [Talos Linux](https://www.talos.dev/) Kubernetes cluster.**

![Talos](https://img.shields.io/badge/Talos-Linux-ff7300)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326ce5?logo=kubernetes&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Last commit](https://img.shields.io/github/last-commit/yama6a/talos-raspberry-pi5-cluster)

<p align="center">
  <img src="docs/images/rackmount_0.jpeg" alt="The assembled 3-node Raspberry Pi 5 cluster in a 10-inch rack" width="600">
</p>

> Hardware, OS and cluster bring-up, documented end to end. Flash the NVMe drives, configure Talos, bootstrap
> etcd, and hand over a working `kubeconfig`. Everything that runs *on* the cluster lives in the platform repo.
>
> Three repos, in order:
> [talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5) builds the node image,
> **this one** stands up the cluster,
> [offgrid](https://github.com/yama6a/offgrid) delivers the platform and workloads onto it.

## Contents

- [Overview](#overview)
- [Hardware](#hardware)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Where this repo stops](#where-this-repo-stops)
- [Day-2 operations](#day-2-operations)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)
- [Contributing](CONTRIBUTING.md)
- [License](#license) and [Credits](#credits)

## Overview

- Three Raspberry Pi 5s, every node a control-plane node: HA etcd, workloads co-located.
- Booting Talos off NVMe. Talos ships no official Pi 5 image, so this flashes a release of
  [yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5): a Raspberry Pi kernel at 4K pages
  (Longhorn and XFS need that), plus the extensions the cluster needs.
- A 4th bay takes a worker, and it does not have to be a Pi: the node list carries a hardware type per node and
  resolves the image from it, so an x86 box joins from Image Factory by the same two commands.
- Config is three files: committed `versions.env` (the renovate-managed Talos + Kubernetes pins), plus gitignored
  `inventory.yaml` (your nodes) and `.env` (VIP, sizing, registry auth), each copied from a committed template.
  Nothing is hardcoded in a script.
- Two Helm charts live here because they are hardware- and OS-specific, and are published to `ghcr.io` for the
  platform repo to deliver: `nic-keeper` (the Pi 5 `macb` NIC agent) and `coredns` (scheduling constraints
  patched onto the Deployment Talos owns).

## Hardware

3x Raspberry Pi 5 (8 GB), all control-plane, NVMe-booted, in a 10" 2U half-rack. See
[docs/01_hardware.md](docs/01_hardware.md) and [docs/04_worker_nodes.md](docs/04_worker_nodes.md).

| Component    | Choice                                       | Qty                  |
|--------------|----------------------------------------------|----------------------|
| SBC          | Raspberry Pi 5, 8 GB                         | 3                    |
| Rack         | GeeekPi DP-0046 (10" 2U)                     | 1                    |
| NVMe carrier | 52Pi RS-P11 boards                           | 4 (1 unused for now) |
| SSD          | Crucial P310 1 TB (CT1000P310SSD8, ~220 TBW) | 3                    |
| Power        | 27 W USB-C PD (5.1 V / 5 A)                  | 3                    |
| Cooling      | Pi 5 active cooler + aluminum heat sink      | 3                    |

Why these parts:

- Endurance-focused SSDs: all-control-plane means constant fsync-heavy etcd writes.
- 8 GB: headroom for co-locating etcd and workloads.
- Power delivery into the Pi's own USB-C port, which is the only way to get the full 5 A.

## Repository layout

```
.
|-- Makefile                # thin dispatcher over lib/shell; run `make help`
|-- versions.env            # committed: the Talos + Kubernetes pins (renovate-managed)
|-- inventory.example.yaml  # template for the node list; copy to inventory.yaml
|-- .env.example            # template for config + secrets; copy to .env
|-- docs/                   # the numbered runbook + decision records (01 to 06)
|-- charts/                 # nic-keeper + coredns, published to ghcr.io for the platform repo
|-- lib/
|   |-- shell/              # every bootstrap script + the shared common.sh
|   `-- talos/              # Image Factory schematics for node types without a custom build
`-- secrets/                # gitignored: talos certs, talosconfig, kubeconfig
```

## Getting started

Only ever run on macOS, so Linux or WSL may need tweaks. The scripts assume a bash/zsh shell, GNU `make`, and a
POSIX-y environment.

On your machine: `docker` (with host networking), `git`, `kubectl`, `yq`. No native `talosctl` needed: it runs
dockerized via `make talosctl`, because the macOS build is unreliable however you install it.

```bash
# 0. Assemble the hardware (docs/01) and flash each Pi's EEPROM boot order (insert microSD into your laptop)
make build-eeprom-card              # 02 - write the EEPROM boot config to a microSD card (same card for all nodes)

# Now insert the SD card into each Pi one-by-one, power on, wait for the LED to flash green rapidly, which means
# flashing is done, then power off and remove the card.

# 1. Configure - versions.env is committed; copy the two templates
cp inventory.example.yaml inventory.yaml   # then edit: one entry per node (role, hardware type, image)
cp .env.example .env                       # then edit: cluster name, VIP, sizing, GHCR auth

# 2. Flash the NVMe drives: connect each NVMe to your laptop (e.g. via a USB adapter) and run, per drive:
make flash-talos-nvme               # 03a - pick a node from the inventory, write its Talos image (repeat per drive)

# 3. Verify the nodes boot into Talos maintenance mode
make verify-talos-boot              # 03b - confirm each node boots into maintenance mode

# 4. Bring up the cluster
make bootstrap-cluster              # preflight + boot-verify + config + etcd + NIC hardening

# 5. Verify
make check-health                   # Talos cluster health
eval "$(make print-kubeconfig)"     # point kubectl at the cluster
kubectl get nodes                   # all present, all NotReady until a CNI lands
```

Instead of `make bootstrap-cluster` you can run the steps in runbook order. Every target maps to a script in
`lib/shell/`; `make help` lists them all. Per-phase reasoning and verification is in [the docs](#documentation).

## Where this repo stops

`make bootstrap-cluster` ends with a configured cluster, etcd bootstrapped, and a `kubeconfig` in `secrets/`.
**Nodes stay `NotReady` on purpose**: nothing has installed a CNI, and that is the first thing the platform repo
does.

Continue in [yama6a/offgrid](https://github.com/yama6a/offgrid):

```bash
make bootstrap-cluster              # installs Cilium, then Argo CD delivers everything else from git
```

Both repos read the same credentials because `secrets/` is a symlink to the same off-repo store in each. If that
symlink is missing on the platform side, point it at the same directory before running.

The division of labour:

| This repo | The platform repo |
|---|---|
| Hardware, EEPROM, NVMe flashing | The CNI (Cilium) and everything above it |
| Talos machine config, etcd bootstrap, PKI | Argo CD and every app it delivers |
| Talos and Kubernetes upgrades | Ingress, TLS, SSO, storage, databases, messaging, monitoring |
| Node loss and replacement | Off-cluster S3 backups and restores |
| `nic-keeper` + `coredns` charts (published to ghcr.io) | Consuming those charts as pinned dependencies |

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
| Inspect                   | `make check-health`, `make talosctl <args>`, `eval "$(make print-kubeconfig)"` |

A Talos or Kubernetes bump is two steps: merge the Renovate PR that moves the pin in `versions.env`, then run
the upgrade target. Merging alone changes nothing on the nodes.

## Troubleshooting

- **`talosctl` misbehaves on macOS**: use the dockerized `make talosctl <args>`. A native client is not required
  ([docs/03](docs/03_operating_system.md)).
- **Nodes are `NotReady` after bring-up**: expected. Nothing here installs a CNI; the platform repo does.
- **Intermittent NIC drops on a Pi 5**: the `macb` wedge, handled by NIC hardening (03d) plus the `nic-keeper`
  DaemonSet ([docs/03](docs/03_operating_system.md)).
- **A node came back after a reflash and will not rejoin**: its etcd member and Longhorn disk records outlive the
  disk. `make recover-node NODE=<host>` ([docs/05](docs/05_node_recovery.md)).
- **Both CoreDNS replicas landed on one node**: the anti-affinity patch is delivered by the platform repo at
  wave 0, so it only applies once Argo CD is running ([docs/03](docs/03_operating_system.md)).

## Documentation

| Doc                                                | Covers                                                                       |
|----------------------------------------------------|------------------------------------------------------------------------------|
| [01_hardware](docs/01_hardware.md)                 | Bill of materials + the reasoning behind every part.                         |
| [02_raspi_eeprom](docs/02_raspi_eeprom.md)         | Flashing a common Pi 5 EEPROM boot config.                                   |
| [03_operating_system](docs/03_operating_system.md) | Talos: OS choice, where the Pi 5 image comes from, cluster bring-up, NIC hardening, CoreDNS placement. |
| [04_worker_nodes](docs/04_worker_nodes.md)         | The node inventory, and adding a worker that does not have to be a Pi.       |
| [05_node_recovery](docs/05_node_recovery.md)       | Losing or replacing a node: etcd, Talos, Longhorn, CNPG, RabbitMQ.           |
| [06_renovate](docs/06_renovate.md)                 | Automated dependency updates and when Renovate is allowed to self-merge.     |

Repo-wide conventions are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

- Talos Linux by [Sidero Labs](https://www.siderolabs.com/).
- The Pi 5 node image comes from [yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5),
  which credits its own upstreams.

## License

MIT. See [LICENSE](LICENSE).
