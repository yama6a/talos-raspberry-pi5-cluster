# Node recovery runbook

The reasons behind these steps are in [05_node_recovery.md](../05_node_recovery.md). The examples use
`talos-cp3` at `192.168.10.203` as the lost node and `192.168.10.201` as a survivor.

## Replace a node

```bash
make flash-talos-nvme                # only if the NVMe is new. Pick the node, then boot it with no SD card
make recover-node NODE=talos-cp3     # steps 3, 5 and 7 below. Safe to re-run
make rebalance-workloads             # once everything is healthy
```

`recover_node.sh` checks before every action, so re-running it is how you get past a step that needed more time.

## By hand, if the script stops half way

Address nodes by IP. Never run `talosctl bootstrap`: that creates a new cluster.

1. Confirm the node is gone, not just slow to boot:

   ```bash
   arp -n 192.168.10.203          # "(incomplete)" means no layer-2 presence at all
   nc -vz 192.168.10.203 50000    # Talos API
   ```

   No ARP entry means the node did not boot or its NIC did not come up. Attach HDMI or a USB-UART console
   (115200 baud, `ttyAMA10`) to tell which.

2. Check the survivors hold quorum. Two of three do, with no spare failure left:

   ```bash
   make talosctl -- -n 192.168.10.201 etcd members    # 3, one unreachable
   kubectl get nodes
   ```

3. Remove the stale etcd member. It takes the member ID, not the hostname:

   ```bash
   make talosctl -- -n 192.168.10.201 etcd remove-member <member-id>
   make talosctl -- -n 192.168.10.201 etcd members    # 2
   ```

4. Reflash and boot the node. It comes up in maintenance mode:

   ```bash
   make talosctl -- -n 192.168.10.203 version --insecure
   ```

5. Apply its machine config. `03c` renders from the kept `secrets/secrets.yaml`, so the PKI stays the same:

   ```bash
   make add-node NODE=talos-cp3
   ```

   Expected: `Applied configuration without a reboot`, then the node ready. It joins etcd by itself.

   ```bash
   make talosctl -- -n 192.168.10.201 etcd members    # 3, with a new ID for the replaced node
   kubectl uncordon talos-cp3                         # if it came back cordoned
   ```

   If the node object is stuck on a stale identity, run `kubectl delete node talos-cp3` and let the kubelet
   register again.

6. Reconcile the storage layer, if it keeps per-node records. The node reports `Ready`, so a refused disk stays
   hidden until you look. Whatever deploys the storage layer owns this step.

7. Verify:

   ```bash
   kubectl get nodes                                  # 3 Ready, no out-of-service taint
   make talosctl -- -n 192.168.10.201 etcd members    # 3 members
   kubectl get pods -A | grep -Ev 'Running|Completed' # empty
   ```

   The outage leaves pods in phase `Failed`, and nothing cleans them up. The script counts them at the end:

   ```bash
   kubectl delete pods -A --field-selector=status.phase=Failed
   ```

## Retire a node for good

1. Remove it from etcd and Kubernetes:

   ```bash
   make talosctl -- -n 192.168.10.201 etcd members             # find the ID
   make talosctl -- -n 192.168.10.201 etcd remove-member <id>
   kubectl delete node talos-cp3
   ```

2. Remove its entry from `inventory.yaml`, so the scripts stop targeting it.
3. Add a replacement soon. Two nodes have no fault tolerance.
