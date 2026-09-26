# The node inventory, and workers

Where the node list lives, and what changes when a node is not a control-plane Pi. Procedures are in the
[worker nodes runbook](runbooks/04_worker_nodes.md).

## inventory.yaml

A node has a role, a hardware type and its own image source. So the node list is a YAML file, not a flat `.env`
string. `inventory.example.yaml` documents every field. `common.sh` parses the file once and derives the arrays
every script iterates.

- **Derived, not stored.** Seven keys, one of them optional. There is no `arch`: `imageFile` names it and the
  kubelet sets `kubernetes.io/arch`. Which `03b` checks run and whether `03d` hardens the NIC follow from `type`.
- **`installDisk` has no default.** A default of `/dev/nvme0n1` would let a forgotten value install to a device
  nobody looked at. `03b` and `03c` both check that the node has the disk before anything is written.
- **`imageSource` is spelled out, although `imageSchematic` implies it.** "Where does this node's image come
  from?" is the most useful question about a node, so the answer is visible, not deduced. `common.sh` checks
  that the two agree.
- **No hardware-type table.** A node's whole definition sits in one entry. The cost: nodes of the same type repeat
  five fields and could disagree. `common.sh` checks presence, the two enums and unique hosts and IPs. It cannot
  catch an image for the wrong architecture, which you find at boot.

## Two image sources

Each node needs two artifacts, a raw image for `03a` to flash and an installer for `03c` and `03e`:

| `imageSource` | Raw image | Installer | Checksum |
|---|---|---|---|
| `github-release` | a release asset on `github.com/<repo>/releases/download/${TALOS_IMAGE_RELEASE}/` | a container at `${TALOS_IMAGE_REPO}:${TALOS_IMAGE_RELEASE}` | yes, `sha256sums.txt` |
| `image-factory` | `factory.talos.dev/image/<id>/${TALOS_VERSION}/<imageFile>` | `factory.talos.dev/metal-installer/<id>:${TALOS_VERSION}` | none, HTTPS only |

- The Pi build exists for the rpi5 overlay and a patched kernel. An x86 node needs neither, so it takes a stock
  Image Factory image built from `lib/talos/schematic-amd64.yaml`.
- The schematic id is a content hash, resolved at run time, so there is no id to pin and none to go stale.
- The inventory never names a version. One `TALOS_IMAGE_RELEASE` bump moves every node, because `TALOS_VERSION`
  derives from it.
- Extension pinning differs by source. The Pi image carries what its release built. The factory resolves the
  schematic's extension names per Talos version. Both are correct, so do not try to unify them.

## What a worker's config leaves out

A worker gets a strict subset of the control-plane config, from the same script:

| | Control-plane | Worker |
|---|---|---|
| `--output-types` | `controlplane,talosconfig` | `worker` |
| VIP and `machine.network.interfaces` | on `end0` | left out |
| `apiServer.certSANs` | the VIP plus every control-plane IP | n/a |
| etcd timeouts, `allowSchedulingOnControlPlanes` | yes | n/a |
| `cluster.network.cni`, `cluster.proxy` | yes | n/a, a worker reads neither |
| kubelet mounts, image GC age, KubePrism, volumes | same | same |

- **No interfaces block on a worker.** x86 NIC names depend on the firmware (`eno1`, `enp0s31f6`), and a wrong
  guess is a node with no network. Talos runs DHCP on every link by default, and a worker carries no VIP.
- **Install image, install disk and the instance-type label are per node**, in their own patch at apply time. So
  one `gen config` per role serves any mix of hardware.
- **Only control-plane nodes are `talosctl` endpoints.** A worker cannot proxy the Talos API. `-n <worker-ip>`
  still reaches it through a control-plane endpoint.
- **A worker joins schedulable.** `03g` refuses to run while any node is cordoned. A cordoned worker during a
  bootstrap also packs everything onto the Pis.

## Mixed architectures

The scheduler ignores image architecture. An arm64-only image placed on an amd64 node fails with
`exec format error` and crashloops.

- The check belongs with whatever deploys the workloads. It must read the live pods, because most images come
  from upstream and a digest pin can hide a single-platform image.
- Run it before the first node of a new architecture joins.
- A failing image needs a multi-arch build, or a `nodeAffinity` on `kubernetes.io/arch`.

## Reset order: workers first, and finished

A worker has no Talos CA key. Its `apid` gets a certificate from `trustd`, which runs only on control-plane
nodes. So a worker's Talos API lives only while a control-plane node is up.

If everything resets in parallel:

- the faster control-plane nodes go down first
- the worker's `apid` dies with `trustd`, mid-reset, and cannot come back
- the worker's disk is never wiped, and every reboot hangs at `service "apid" to be "up"`
- Talos has no shell, so the only fix is a physical reflash

`DANGEROUS_reset_talos_cluster.sh` therefore resets the workers first and waits until each answers the
maintenance API again. If a worker fails, it stops with the control plane still up, so you can retry. `03e`
upgrades workers first for a milder reason: a failure there costs no quorum.

## Scheduling: a bigger node takes a bigger share

`NodeResourcesFit` scores free capacity as a fraction, so nodes converge on the same percentage full. A node with
4x the memory ends up with about 4x the requests. Nothing balances pod count.

- This is accepted. Single-replica pods are what lands on a new node, so the multi-arch check matters.
- The blast radius follows the share. The Pis cannot absorb a large node's pods if it dies, so alert on
  cluster-wide memory overcommit.
- The lever, if it matters, is to advertise less than the hardware has. See the runbook.

## The x86 schematic

`lib/talos/schematic-amd64.yaml`. Talos ships `i915` as a module, and the base image has no GPU firmware. Without
the extension the box has no `/dev/dri`, and every transcode runs in software.

- `i915` covers Intel Gen9 through Xe1 graphics. Xe2 and newer need `siderolabs/xe`.
- `siderolabs/mei` (for discrete Arc cards) and `siderolabs/intel-ice-firmware` (for E810 NICs) do nothing for an
  iGPU, although many guides list them.
- Talos labels the node `extensions.talos.dev/i915`, so a device plugin selects on that without
  node-feature-discovery.
- `/dev/dri/renderD128` is mode `0666`, and there is no `render` group to resolve, so a consumer needs no
  `supplementalGroups`.
- HuC low-power encode stays off on Gen9.5. To try it, add `i915.enable_guc=2` to `extraKernelArgs`.
- `talos.dashboard.disabled=1`: a node with a console starts a dashboard, and machined logs every poll feeding
  it. Talos turns it off on SBCs by default, so only the x86 box needs it.
- Boot UEFI, never legacy BIOS. Talos boots UEFI with systemd-boot and a UKI, and legacy BIOS through GRUB has an
  open boot failure report on HP hardware (siderolabs/talos#13224). The UKI bakes in the kernel command line, so
  kernel args go in the schematic's `customization.extraKernelArgs`, not in `machine.install.extraKernelArgs`.
