# Talos: OS, node image, cluster config and upgrades

The cluster runs Talos Linux: immutable, managed only through its API, built for Kubernetes. Procedures are in
the [operating system runbook](runbooks/03_operating_system.md).

This doc covers the three Pi 5 control-plane nodes. What differs for a worker, or for hardware with no custom
build, is in [04_worker_nodes.md](04_worker_nodes.md).

## Why Talos

- The whole node is one declarative config, managed through `talosctl`.
- Every board runs the same image. Only the config makes a node different.
- Upgrades are atomic A/B with rollback, through `talosctl upgrade`. Nothing changes in place.
- Small attack surface: no shell, no SSH, about 12 host binaries. WiFi, Bluetooth and cron are not in the image.
- Kubernetes is built in. PCIe, cgroups and link speed are set in the image, with no `config.txt` edits.

Costs:

- Talos ships no Pi 5 image. The BCM2712 SoC and the RP1 I/O chip need drivers from the `raspberrypi/linux` fork.
- A Talos upgrade needs a new image build, in a separate repo that needs its own maintenance.
- No shell. A hung node gets rebooted, not logged into.

## OSes considered

| OS / distro                                | Verdict                                                                                    |
|--------------------------------------------|--------------------------------------------------------------------------------------------|
| Talos Linux                                | Chosen. Immutable, declarative, identical nodes, Kubernetes built in.                      |
| k3s on Ubuntu Server                       | Runner-up. 4K pages and cgroups out of the box, largest community. But mutable.            |
| k3s / kubeadm on Raspberry Pi OS           | Needs a manual cgroup edit in `cmdline.txt` and a switch from the 16K-page kernel to 4K.   |
| k0s on Ubuntu                              | Smallest footprint, clean `k0sctl` spec. Smaller community, no gain over Talos.            |
| NixOS + k3s                                | Fully declarative, the closest rival. Steep learning curve, smaller Pi 5 community.        |
| Flatcar / Fedora CoreOS / openSUSE MicroOS | Also immutable, but with less mature Pi 5 support.                                         |
| Harvester                                  | A full HCI and KubeVirt stack. Needs x86_64 and much more RAM.                             |

## The node image

Stock `metal-arm64` cannot boot a Pi 5: it has no Pi 5 boot chain (u-boot and the BCM2712 device tree). So the
image is built in [yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5). That repo owns the
build, the kernel decisions and the releases. This repo uses a release in two ways:

- `03a` writes the release's raw disk image onto each NVMe, once per drive.
- `03e` upgrades running nodes to the release's installer image over the network.

Upstream's `siderolabs/sbc-raspberrypi` `rpi_5` overlay is not an option yet:

- Its kernel side works. The mainline kernel carries the Pi 5 NIC (needs Linux >= 6.18), and stock Talos enables
  it.
- It cannot boot from NVMe. Its u-boot is built for the Pi 4 and has no `brcm,bcm2712-pcie` driver, so u-boot
  cannot read the disk it was loaded from.
- Tested on a node here: the upgrade applied, then the board went dark with no layer-2 presence.
- The evidence and the plan to move to upstream are in that repo's `docs/upstream.md` and `FUTURE_WORK.md`.

What the image carries that this cluster depends on:

- 4K kernel pages, as in stock `metal-arm64`, instead of the Pi defconfig's 16K. Some storage software does not
  work with 16K pages.
- The `iscsi-tools` extension, because iSCSI-based CSI drivers need `iscsid`, and `util-linux-tools` for
  `fstrim`.
- Built-in drivers that `03d` and a storage layer need: the Pi 5 watchdog, NVMe over PCIe, the `macb` NIC and
  RP1 bring-up. Also `INET_DIAG_DESTROY`, which lets `nic-keeper` close sockets with `ss -K`.
- WiFi and Bluetooth off in the device tree. The VIP still binds to `end0` by name, so it can never land on a
  wireless link.

## Versions

Every pin lives in the committed `versions.env`, and Renovate opens PRs to bump them.

- `TALOS_IMAGE_RELEASE` names a release of the image repo as `<talos version>-<build revision>`. `common.sh`
  derives `TALOS_VERSION` from it, so the `talosctl` client never drifts from the image.
- `KUBERNETES_VERSION` is what `03c` generates config for and `03f` upgrades to. It cannot exceed the Kubernetes
  default of the pinned Talos release, so raise it only after the Talos bump.
- Merging a bump changes only `versions.env`. `make upgrade-talos` or `make upgrade-k8s` applies it, and a fresh
  drive needs `make flash-talos-nvme`.

## Cluster config

`03c` renders the machine config from `inventory.yaml`, `versions.env` and `.env`. The reasons for each setting
are comments in `lib/shell/03c_talos_cluster_config.sh`. The decisions that shape the cluster:

- **Every node is control-plane and schedulable.** Three nodes give HA etcd and still run workloads.
- **One cluster PKI, never rotated.** `secrets.yaml` is generated once. The rest of the config is rendered fresh
  on every run, so a version bump in `versions.env` reaches the nodes.
- **No CNI by default.** `DISABLE_FLANNEL_AND_KUBE_PROXY="true"` turns off both Flannel and kube-proxy, for a CNI
  that replaces both. One switch drives both keys, because Flannel does not replace kube-proxy. The choice is
  fixed at bootstrap.
- **The VIP floats between control-plane nodes.** Talos claims it over ARP, so it must sit outside the DHCP pool
  and cannot be reserved to a MAC.
- **etcd timeouts are 5x the defaults.** etcd shares one NVMe with storage and databases. During a cold boot its
  fsyncs stall past the default election window and trigger a burst of leader elections. The cost is about 5s
  instead of 1s failover when a leader really is gone.
- **EPHEMERAL is capped, and a `storage` volume takes the rest of the disk.** Talos provisions each volume once.
  An `EPHEMERAL_SIZE` change reaches new nodes only, and renaming the volume orphans the old partition.
- **Registry auth sits on the node.** With `GITHUB_GHCR_PULL_TOKEN_SECRET` set, every node authenticates every
  `ghcr.io` pull, so no workload needs `imagePullSecrets`. The cost: the token lives in the machine config, and
  rotating it means a new `.env` value and `make reapply-talos-config`. GHCR accepts only a classic token.

## Upgrades

`03e` upgrades Talos one node at a time, workers first. A worker holds no etcd, so a failed upgrade there costs no
quorum.

`03e` drains each node itself before `talosctl upgrade`, because Talos's own drain hangs on three kinds of pod:

| Pod | Why a graceful drain hangs |
|---|---|
| a single-instance database | its operator's PDB is `minAvailable: 1`, so any eviction violates it |
| a per-node storage engine | its PDB blocks the drain while the node holds a volume's last healthy replica |
| a broker with hard one-per-node anti-affinity | it terminates slowly and has nowhere to reschedule, so Talos's bounded drain times out |

None of them can move, so a drain can only kill them, and they return on the same node after the reboot. Per
node, `03e`:

1. Waits for `PRE_DRAIN_HEALTH_HOOK` to pass, if set. This also waits out the previous node's resync.
2. Runs `PRE_DRAIN_EVACUATE_HOOK` once, if set, to move roles such as a database primary off the node. Then it
   checks health again.
3. Cordons and drains gracefully, then force-deletes stragglers so the node can always reboot.
   `FORCE_DELETE_SKIP` spares pods that must not be force-killed.
4. Upgrades, waits for cluster health, and uncordons.

- **Health is the cluster's own business.** This repo cannot know what the cluster runs, so the check is a hook.
  Left empty, nothing gates the reboot, and `03e` warns.
- **etcd is not the hook's job.** `talosctl upgrade` refuses to reboot if that would break quorum.
- **A storage layer's own "drain replicas off the node" option stays off.** Rebuilding replicas elsewhere needs a
  spare node and is slow on 3 nodes with 2 replicas. The health hook waits for the storage layer to rebuild a
  degraded volume by itself instead.
- **Kubernetes upgrades separately.** `03f` runs `talosctl upgrade-k8s`, which rolls the control plane and
  kubelet in place and reboots nothing.

### Rebalancing

A node-by-node drain leaves pods bunched on the nodes that were up last. Nothing moves them back: there is no
descheduler, and spread constraints are the workloads' own business. `03g` rolling-restarts the stateless
Deployments so the scheduler places them again. `03e` runs it at the end.

- A nudge, not a guarantee. The scheduler scores each pod alone, so a run can still clump. The real fix is
  `topologySpreadConstraints` on the workloads.
- Refuses to run unless every node is Ready, schedulable, and counted in `inventory.yaml`. Restarting with a node
  cordoned only packs the others.
- Skips a Deployment in `REBALANCE_SKIP_NAMESPACES`, one scaled to 0, and one that mounts a PVC. A PVC is moved
  only in `REBALANCE_PVC_NAMESPACES` and only with the `Recreate` strategy.
- Tests for a PVC, not for a name, so operator-generated names cannot make the list go stale.

## NIC hardening

The Pi 5 `macb` NIC wedges ([sbc-raspberrypi #91](https://github.com/siderolabs/sbc-raspberrypi/issues/91)). A
newer kernel does not fix it, so the fix is config and a runtime agent. `03d` applies both halves before any CNI
is installed, so the NIC is hardened before the network-heavy CNI rollout.

| Trigger | Fix | Where |
|---|---|---|
| silent TSO/GSO transmit-ring hang | offloads off, receive and transmit rings at the NIC maximum (`EthernetConfig`) | `03d`, machine config |
| full node hang | hardware watchdog reboots the node (`WatchdogTimerConfig`) | `03d`, machine config |
| Energy Efficient Ethernet wakes the link too slowly | `ethtool --set-eee end0 eee off` | `nic-keeper` |
| link up, but no traffic passes | a ping probe, then `ip link` down and up | `nic-keeper` |
| kubelet's API sockets hang after a link bounce | `ss -K` drops them so they reconnect | `nic-keeper` |

The machine-config half, `03d`:

- Reads the ring maximums, offload keys and watchdog device from the live node, instead of hardcoding them.
- Patches documents with `talosctl patch mc --mode no-reboot`, so it never reboots a node and never replaces the
  config `03c` applied.
- Waits for the API to answer steadily over the VIP before it exits. The ring change bounces `end0`, which
  carries the VIP.

The runtime half, `nic-keeper`, one pod per Pi 5 node:

| Decision | Why |
|---|---|
| DaemonSet | the fix is per node, on the host's NIC and network namespace |
| one agent for all three runtime fixes | one wedge triggers all three, so one loop beats three pods racing |
| a runtime agent, not machine config | Talos has no `EthernetConfig` field for EEE, and wedge detection has to react |
| a ping probe, not the carrier state | a wedged link keeps carrier up, so only traffic shows the wedge |
| `NET_ADMIN` and `NET_RAW`, not `privileged` | enough for `ethtool`, `ip link`, `ss -K` and `ping` |
| applied by `03d`, not by a GitOps tool | it is the other half of `03d` and must run before the CNI. Nothing reconciles it |
| `instance-type: rpi5` node selector | the wedge is Pi 5 only. `03c` stamps the label from the node's `type` in `inventory.yaml`, and that label key is one the kubelet may set |

- It lands before any CNI, because the DaemonSet controller tolerates `node.kubernetes.io/not-ready` and the pod
  uses the host network.
- A recovery bounces the link for about 2s. The loop never blocks, so it never trips the hardware watchdog.

## Reference

- Pi 5 Talos image, its build and releases: <https://github.com/yama6a/talos-raspberry-pi5>
- Talos releases: <https://github.com/siderolabs/talos/releases>
- Upgrading Talos: <https://www.talos.dev/latest/talos-guides/upgrading-talos/>
- The Pi 5 `macb` wedge: <https://github.com/siderolabs/sbc-raspberrypi/issues/91>
- KubePrism, the local apiserver endpoint a CNI uses before pod networking exists:
  <https://www.talos.dev/latest/kubernetes-guides/configuration/kubeprism/>
