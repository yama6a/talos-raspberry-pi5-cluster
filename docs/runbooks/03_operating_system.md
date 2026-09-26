# Operating system runbook

Flash, boot, bring up, harden and upgrade the Talos cluster. The reasons behind each step are in
[03_operating_system.md](../03_operating_system.md). `make help` lists every target.

## Flash the NVMe drives

Runs on macOS. Repeat for each drive.

1. Connect the NVMe to your laptop through a USB adapter.
2. Write the image:

   ```bash
   make flash-talos-nvme            # pick a node from the list, or pass NODE=<host>
   ```

   The script downloads the image once per release, checks its sha256, and asks for the disk id.
3. Enter the whole-disk id, for example `/dev/disk6`, not a partition. Type `YES` to erase it.
4. Slot the drive into its Pi and power on with no SD card. Talos boots into maintenance mode.

The pick selects the image, not the drive, so one run covers every drive of the same hardware type.

## Reserve the IPs

1. Boot each Pi once and read its MAC address from the router's client list.
2. Reserve one IP per node in the router. Put the same IPs in `inventory.yaml`. Example:

   | Node | IP |
   |---|---|
   | talos-cp1 | 192.168.10.201 |
   | talos-cp2 | 192.168.10.202 |
   | talos-cp3 | 192.168.10.203 |

3. Pick the VIP: an unused IP inside the subnet and outside the DHCP pool. Do not reserve it in the router. Set it
   as `CLUSTER_VIP` in `.env`.

## Verify the boot

```bash
make verify-talos-boot
```

Expected: `summary: N passed, 0 failed`. Per node it checks the Talos API port, the Talos version, the wired NIC
and the install disk. On a Pi 5 it also checks the overlay's kernel cmdline.

## Bring up the cluster

The one-shot path, which runs the boot check, archives old credentials, configures the nodes, bootstraps etcd and
hardens the NICs:

```bash
make bootstrap-cluster           # asks you to type BOOTSTRAP
```

Or step by step:

```bash
make init-talos                  # every node must be in maintenance mode
make harden-nics
```

`03c` has three entry points. They differ only in how the same render is applied:

| Target | Nodes must be | Applies | Bootstraps etcd |
|---|---|---|---|
| `make init-talos` | all in maintenance | `--insecure` | yes, once |
| `make add-node NODE=<host>` | that one in maintenance | `--insecure` | no, it joins by itself |
| `make reapply-talos-config [NODE=<host>]` | already running | authenticated, `--mode auto`, after a dry run and a confirm | no |

Gotchas:

- Bootstrap runs on one node only. Never run it on another node, or etcd splits into two clusters.
- `make init-talos` cannot change a running cluster. It waits for maintenance mode and fails after 300s per node.
  Use `make reapply-talos-config`.
- Volume sizes are fixed when a node is first configured. An `EPHEMERAL_SIZE` change reaches new nodes only.

## Verify the cluster

```bash
make check-health
make merge-kubeconfig
kubectl get nodes -o wide                                # all present, NotReady until a CNI is installed
make talosctl -- -n <cp1-ip> etcd members                # 3 members
```

## Harden the NICs

`make bootstrap-cluster` runs this. Run it by hand after a change to `lib/k8s/nic-keeper.yaml` or a Renovate bump
of its image.

```bash
make harden-nics
```

Expected: `[PASS]` per check, then `summary: N passed, 0 failed`.

| Failure | Meaning |
|---|---|
| `patch` fails and mentions a reboot | the change needed a reboot and the script refused. Investigate before you force it |
| watchdog not armed | the timeout is above the hardware maximum. Lower `WATCHDOG_TIMEOUT` in `03d` |
| API not steady | the VIP did not settle in time. Wait, or raise `SETTLE_WAIT`, before you install a CNI |

Check `nic-keeper`:

```bash
kubectl get ds -n kube-system nic-keeper                          # DESIRED = CURRENT = READY = 3
kubectl logs -n kube-system -l app.kubernetes.io/name=nic-keeper  # one pod per node, event=eee-off ok
kubectl get nodes -L node.kubernetes.io/instance-type             # every Pi shows rpi5
```

A recovery in a pod's log looks like this:

```
... event=probe-fail target=192.168.10.1 carrier=1 count=4/4
... event=wedge fail_count=4 threshold=4 carrier=1 (bouncing link)
... event=ss-kill filter='dport = :6443' result=...
... event=recovery link bounced + eee re-asserted; cooldown=60s
```

## Upgrade Talos

1. Merge the Renovate PR that bumps `TALOS_IMAGE_RELEASE`.
2. Run the upgrade. It asks you to type `yes`, then reboots each node in turn:

   ```bash
   make upgrade-talos
   ```

3. Check the result: `make talosctl -- version` and `kubectl get nodes`.

If it stops, re-run it. Nodes already on the target image are skipped.

Gotcha: when a graceful drain times out, Talos's own drain can still find a terminating pod and fail with:

```
error when evicting pods/"instance-manager-..." -n "longhorn-system":
client rate limiter Wait returned an error: rate: Wait(n=1) would exceed context deadline
```

`03e` leaves the node uncordoned. Re-run it. If it recurs on the same node, raise `GRACEFUL_DRAIN_TIMEOUT` in
`03e`. Do not lower `FORCE_GRACE`.

## Upgrade Kubernetes

1. Upgrade Talos first if the new version is above the pinned Talos release's default.
2. Merge the Renovate PR that bumps `KUBERNETES_VERSION`.
3. Run it. No node reboots:

   ```bash
   make upgrade-k8s
   ```

4. Check: `kubectl get nodes` shows the new version on every node.

## Rebalance the workloads

`make upgrade-talos` runs this at the end. Run it by hand after a node recovery:

```bash
make rebalance-workloads
```

It prints the pod spread before and after.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `download failed` while flashing | `TALOS_IMAGE_RELEASE` names a release that does not exist. Check the image repo's releases |
| `checksum mismatch` while flashing | a truncated download. Delete `.cache/images/<release>/` and re-run |
| `talosctl` on macOS says `no route to host` but `nc` connects | the native macOS build. Use `make talosctl <args>` |
| a node never appears on the network | the kernel lacks the RP1 NIC, or the boot files did not land on the EFI partition. Attach HDMI or a USB-UART console (115200 baud, `ttyAMA10`) |
| a Pi does not boot at all | the EEPROM boot order or `PCIE_PROBE`. See the [EEPROM runbook](02_raspi_eeprom.md) |
| nodes are `NotReady` after bring-up | expected. Nothing here installs a CNI |
| intermittent NIC drops on a Pi 5 | re-run `make harden-nics` and check `nic-keeper` above |
| a node is gone for good | see the [node recovery runbook](05_node_recovery.md). Do not re-run `make init-talos`: it bootstraps a new etcd |

Problems building the image belong to its own repo, see
[docs/build.md](https://github.com/yama6a/talos-raspberry-pi5/blob/main/docs/build.md).
