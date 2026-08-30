# The node inventory, and adding a worker

Where the node list lives, and what changes when a node is not a control-plane Pi.

## inventory.yaml is the node list

Topology outgrew a flat string. A node now has a role, a hardware type, and its own image source, and
`CLUSTER_NODES="host:ip ..."` in `.env` had nowhere to put any of that. So `inventory.yaml` (gitignored, template
in `inventory.example.yaml`) replaces it. `common.sh` parses it once at source time and derives the arrays every
script iterates.

Migrating an existing `.env`: copy the template, fill in your hosts, delete the `CLUSTER_NODES` line. Leaving
that line in is a hard error, because it is no longer read as an array and `${#CLUSTER_NODES[@]}` would quietly
be 1, which would make the node-count gates compare against the wrong number.

| Field | Meaning |
|---|---|
| `host` | the Kubernetes node name; applied via a `HostnameConfig` document |
| `ip` | reserve it in your router; 03c applies config to this address |
| `role` | `controlplane` or `worker`. Decides which config 03c generates |
| `type` | the hardware. Stamped as `node.kubernetes.io/instance-type` |
| `imageSource` | `github-release` or `image-factory`. Where this node's two artifacts come from |
| `imageFile` | the raw-image filename 03a downloads and writes |
| `imageSchematic` | required for `image-factory`, rejected otherwise: the extension set to build with |
| `installDisk` | whole-device path Talos installs to, as the node names it: `/dev/nvme0n1`, `/dev/sda` |

**Seven keys, and only one optional.** Anything that is not a CHOICE is derived rather than stored. There is no
`arch`, because `imageFile` already names it and the kubelet sets `kubernetes.io/arch` itself. There is no
`bootVerify` or `nicHardening`, because which of 03b's checks run and whether 03d hardens the NIC both follow
from `type`: properties of the hardware, not decisions.

`installDisk` has no default, and that is the one place this file spends a keystroke rather than deriving.
Defaulting it to `/dev/nvme0n1` would mean a mistyped or forgotten value installs to a device the operator never
looked at, and a wrong install target is not a failure you want to discover late. 03b and 03c both check the
node actually has it before anything is written. Read it off the node in maintenance mode with
`talosctl -n <ip> get disks --insecure`. The `EPHEMERAL` and `storage` volumes follow it too: both select on
`system_disk` rather than on transport, so a SATA node works with no extra config.

`imageSource` is the exception, and it is deliberate. Its presence IS inferable, from whether the node has an
`imageSchematic`, and an earlier version of this file did exactly that. It reads worse: the single most useful
question about a node ("where does its image come from?") then has no answer you can see, only one you can
deduce. So the discriminator is spelled out, and `common.sh` validates the pair in BOTH directions rather than
leaving them free to disagree.

**No hardware-type table, also deliberately.** Every field sits on the node, so a node's whole definition reads
in one place. The cost is that nodes of the same type repeat five fields and could disagree. `common.sh`
validates presence, the two enums, and uniqueness of hosts and IPs, but it cannot catch a plausible-but-wrong
`asset`: that one writes a bootable-looking image of the wrong architecture, and you find out at boot.

## Two image sources

Each node needs TWO artifacts, and they do not come from the same place:

| `imageSource` | raw image 03a flashes | installer 03c bakes in and 03e upgrades to | checksum |
|---|---|---|---|
| `github-release` | a release ASSET on `github.com/<repo>/releases/download/${TALOS_IMAGE_RELEASE}/` | a CONTAINER at `${TALOS_IMAGE_REPO}:${TALOS_IMAGE_RELEASE}` | yes, `sha256sums.txt` |
| `image-factory` | `factory.talos.dev/image/<id>/${TALOS_VERSION}/<imageFile>` | `factory.talos.dev/metal-installer/<id>:${TALOS_VERSION}` | no, HTTPS only |

The `github-release` row is the one that surprises: same repo NAME, two different hosts, because a release asset
lives on `github.com` and a container lives on `ghcr.io`. `03a` builds the first by stripping the registry
prefix off `TALOS_IMAGE_REPO`.

The Pi build exists for the rpi5 overlay and a patched kernel. An x86 node needs neither, so building one would
be maintenance with no payload; the factory serves a stock image built from a committed extension list
(`lib/talos/schematic-amd64.yaml`). The schematic id is a content hash, POSTed and resolved at run time, so
there is no id to pin and none to go stale.

**Versions stay in `versions.env`.** The inventory says where an image comes from, never which version, so one
`TALOS_IMAGE_RELEASE` bump moves every node: `TALOS_VERSION` is derived from it and the factory resolves both
the image and its extensions against that.

The one asymmetry worth knowing: extension pinning differs by source. The Pi image bakes whatever its release
built; the factory resolves the schematic's names per Talos version. Same upstream versions, different mechanism.
Not something to "fix".

## Adding a worker

```
make flash-talos-nvme         # pick the node from a list; writes its image to an NVMe over USB
make add-node NODE=<host>     # generates + applies its config; it joins on its own
```

The flasher's pick selects the IMAGE, not the drive, so one run covers every drive of the same hardware type.
It asks rather than defaulting to a node, because the wrong pick writes another architecture's image and that
boots to nothing. `NODE=<host>` skips the prompt for a scripted run.

A full `make bootstrap-cluster` needs neither command: 03c iterates the whole inventory, control-plane nodes
first, so a worker is brought up in the same pass. Adding a worker is not a separate operation, it is another
entry in the list.

**It joins schedulable, not cordoned.** A cordon would fight two things: `03g_rebalance_workloads.sh` refuses to
run while any node is cordoned, and during a bootstrap a cordoned worker packs everything onto the Pis and then
needs a rebalance. Cordon by hand if you want to stage it.

## What a worker's config leaves out

A worker gets a strict subset. Not a separate script: the maintenance wait, the registries block, the volume
documents, the `HostnameConfig` apply and the reboot wait are the bulk of 03c and are identical either way.

| | control-plane | worker |
|---|---|---|
| `--output-types` | `controlplane,talosconfig` | `worker` |
| VIP and `machine.network.interfaces` | on `end0` | **omitted entirely** |
| `apiServer.certSANs` | the VIP plus every control-plane IP | n/a |
| `etcd.extraArgs`, `allowSchedulingOnControlPlanes` | yes | n/a |
| `cluster.network.cni`, `cluster.proxy` | yes | n/a, a worker reads neither |
| kubelet `extraMounts`, KubePrism, volumes | identical | identical |

Omitting the interfaces block is what keeps a NIC name we cannot predict out of the config. Talos DHCPs every
link by default and a worker carries no VIP, so nothing needs to name it. Interface naming on x86 is
firmware-dependent (`eno1` on many HP boxes, `enp0s31f6` when firmware omits the onboard index), and guessing
wrong is a node with no network.

`machine.install.image` and the instance-type label are per NODE, not per role, so they ride in their own patch
at apply time. That is what lets one `gen config` per role serve any mix of hardware types.

`talosctl config endpoint` stays control-plane-only: a worker cannot proxy the Talos API. `-n <worker-ip>` still
reaches it through a control-plane endpoint.

## Mixed architectures

Nothing in Kubernetes stops an arm64-only image landing on an amd64 node. The scheduler does not look at image
architecture, so the pod is placed and then `CrashLoopBackOff`s with `exec format error`.

That bites the workloads, not this repo, so the check belongs with whatever deploys them: read the LIVE pods
rather than any config file, because most images come from upstream and never appear in a repo you control,
and a digest pin that resolves to a single platform instead of an index cannot be caught by reading
manifests either. Run it BEFORE the first
node of a new architecture joins, since checking only what the cluster already runs by definition cannot
catch the image that is about to break.

A failing image needs a multi-arch rebuild, or a `nodeAffinity` on `kubernetes.io/arch` so the scheduler stops
offering it nodes it cannot run on.

## Reset order: workers first, and finished

A worker holds no Talos CA key. Its `apid` gets a server certificate signed by `trustd`, which runs only on
control-plane nodes, on port 50001. So a worker's Talos API is alive only while at least one control-plane node
is.

So the reset order decides whether a worker survives, and getting it wrong is not recoverable over the network:

- reset everything in parallel, the (faster) control-plane nodes go down first
- the worker is still mid-sequence, its `apid` dies with `trustd` and cannot come back
- `talosctl` retries a node that will never answer, up to its 30-minute default
- the worker's reset never completes, so nothing on its disk is wiped
- every reboot from there parks at `task startAllServices (1/1): service "apid" to be "up"`, forever

At that point there is no API in, and Talos has no shell. The only way out is a physical reflash.

`DANGEROUS_reset_talos_cluster.sh` resets `WORKER_IPS` first, waits for each to answer the MAINTENANCE api
again, and only then resets `CP_IPS`. It waits for maintenance rather than just for the reset call to return,
because the guarantee needed is that the worker no longer depends on the control plane at all. If any
worker fails either check the script aborts with the control plane still up, so the node is still reachable
and you can retry.

Same reasoning orders `03e_talos_upgrade.sh` workers-first, though there the cost of getting it wrong is only
a lost quorum rather than a reflash.

## Scheduling: a bigger node takes a bigger share

`NodeResourcesFit` scores `(allocatable - requested) / allocatable`, a fraction, so nodes converge on the same
PERCENTAGE full, and a node with 4x the memory settles at roughly 4x the requests. Nothing balances raw pod
count: `pods` is not scorable by that plugin, and `PodTopologySpread` is always scoped to one workload's own
replicas, which does nothing for a cluster made mostly of single-replica Deployments.

That is fine, and deliberately left alone. Two consequences to know rather than rediscover:

- Checking multi-arch images is not optional. Single-replica pods are exactly what lands on a new node.
- Blast radius follows share. A node holding several times a Pi's requests cannot be absorbed by the Pis if it
  dies, so it is worth alerting on cluster-wide memory overcommit.

If that ever matters, the lever is to advertise less than the hardware has:

```yaml
machine:
  kubelet:
    extraConfig:
      systemReserved: {cpu: 8000m, memory: 23Gi}   # a 12-core/32Gi node scores like a 4-core/7.5Gi one
```

`enforceNodeAllocatable` defaults to `["pods"]`, so this changes what the scheduler sees and nothing else:
nothing is OOM-killed for it. Apply with `talosctl patch mc --mode no-reboot`; the kubelet restarts, the node
does not.

## x86 BIOS

Short, because the NVMe arrives pre-installed and there is no boot medium to prioritise.

1. Apply factory defaults, exit.
2. Boot order: the M.2 NVMe first, **UEFI** mode. Disable Fast Boot.
3. Secure Boot: off. Stock Talos images are not signed with a key OEM firmware trusts.
4. After power loss: **On**. A headless node has to come back by itself.
5. Leave TPM on. Inert unless you enable disk encryption.

**Boot UEFI, never legacy/CSM.** Talos 1.10 split bootloaders: systemd-boot with a UKI for UEFI, GRUB kept only
for legacy BIOS, and there is an open report of HP hardware failing to boot in legacy mode since
(siderolabs/talos#13224). A consequence of the UKI: `machine.install.extraKernelArgs` is ignored on a UEFI
install because the cmdline is baked in. Kernel args go in `customization.extraKernelArgs` in the schematic
instead, which is where `talos.dashboard.disabled=1` lives.

## What the x86 schematic carries

`lib/talos/schematic-amd64.yaml`. Talos ships `i915` as a module and puts neither it nor
`/usr/lib/firmware/i915` in the base image, so without the extension the box has no `/dev/dri` at all and every
transcode is software.

- `i915` covers Gen9 through Xe1. Xe2 (Lunar Lake) and newer want `siderolabs/xe`.
- `siderolabs/mei` is for Arc DISCRETE cards and `siderolabs/intel-ice-firmware` is E810 NIC firmware. Most
  guides list both for an iGPU. Neither does anything here.
- Talos labels the node `extensions.talos.dev/i915`, so a device plugin selects on that and
  node-feature-discovery buys nothing.
- `/dev/dri/renderD128` lands `0666` (`50-udev-default.rules`) and there is no `/etc/group` for `render` to
  resolve against, so a consumer needs no `supplementalGroups`. `card0` stays `0600`; transcoding only touches
  the render node.
- HuC for low-power encode is off on Gen9.5 and stays off. To try it: `i915.enable_guc=2` in
  `extraKernelArgs`.
- `talos.dashboard.disabled=1`: only a node with a console starts a dashboard, and machined access-logs every
  poll feeding it. Talos defaults it to 1 on SBCs, so it only bit the x86 box. `talosctl dashboard` still works.

**Reapply BEFORE you upgrade.** A schematic edit changes its content hash, so the factory returns a new id and
installer ref. `talosctl upgrade` installs the image but never rewrites the stored `machine.install.image`, so
upgrading without a reapply leaves the node pointing at the OLD ref and a later recovery reinstalls it without
these.

```
make reapply-talos-config NODE=tc-w1
make upgrade-talos
```

`upgrade-talos` walks every node, and only skips one whose installed image already matches. Expect a full
reboot per node whenever `versions.env` is ahead of what a node runs.

