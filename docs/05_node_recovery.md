# Losing and replacing a node

What breaks when one of the three Pis goes away, what comes back on its own, and what needs hands.

This is the machine layer only. What the workloads on top do about a node loss, and how long they take, is
their own business and is not documented here.

## Losing a machine is uneventful; replacing one needs hands

If the cluster's volumes belong to a replicated storage layer rather than to any one machine, a machine dying
is a rescheduling problem, not a data problem: the pod reattaches its volume on a survivor and starts. Nothing
to delete, nothing to restore.

What needs hands is the other case: a machine coming BACK under the same name after being reflashed. Its etcd
member outlives the disk it describes, and nothing will guess which side is right.

| Record | Why it does not self-heal | Whose job |
|---|---|---|
| its etcd member | a reflashed node has a NEW etcd identity, and the old entry at the same peer URL blocks the join | this repo, `make recover-node` |
| any per-node record the storage layer keeps | a driver that stamped the old filesystem holds a UUID the fresh one does not match | the platform's, after this |

`make recover-node NODE=<host>` does the first. It stops at a Ready, uncordoned, untainted node and says so.

A WORKER has no etcd member at all, so the script skips that phase by reading the node's `role` from
`inventory.yaml`. Everything else, including the machine-config re-apply, is the same call.

## The out-of-service taint

Kubernetes is deliberately slow to hand one machine's disks to another. A node stops answering, and for about
six minutes nothing takes its volumes, in case it is alive and still writing to them.

`node.kubernetes.io/out-of-service:NoExecute` short-circuits it. The taint asserts the machine is genuinely
gone, and on that assertion Kubernetes force-deletes its pods AND releases their volumes at once. Nothing in
this repo applies it, on purpose, because only an operator or something watching the cluster can make that
call.

What this repo does do is CLEAR it, in both `03e` and `recover_node.sh`, next to their own `uncordon`. A node
that keeps the taint accepts no pods, so neither depends on whatever set it still being alive to remove it.

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Two things to know if you run something that applies it automatically:

- **It must never touch a Ready node.** That is what protects an ordinary drain: `kubectl drain` and `03e`
  cordon a machine that is still up. A cordon on its own is NOT a reason to skip, because `talosctl reset`
  cordons a machine that is never coming back.
- **A Pi 5 Talos reboot is back inside ~90s**, shorter than Kubernetes' own NotReady delay plus any sane grace
  period, so a reboot should never trigger it and a rolling upgrade should be unaffected.

## Replace a node

```bash
make flash-talos-nvme                # only if the NVMe itself is being replaced; pick the node, power on with no SD card
make recover-node NODE=talos-cp3     # steps 2 to 4 below, in order, idempotent
make rebalance-workloads             # once everything is healthy
```

`recover_node.sh` does the mechanical part: drops the stale etcd member, applies that node's machine config,
waits for the kubelet, uncordons and untaints. It re-checks before every action, so re-running it is how you
get past a step that needed more time.

The rest of this section is what it does and why, which is what you need when it stops half way. Nodes are
addressed by IP throughout; `talos-cp3` / `192.168.10.203` is the example. Do not run `talosctl bootstrap` at
any point: that is for creating a cluster, not joining one.

1. Confirm the node is really gone, not just slow to boot.

   ```bash
   arp -n 192.168.10.203          # "(incomplete)" = no layer-2 presence at all
   nc -vz 192.168.10.203 50000    # Talos API
   ```

   An incomplete ARP entry means it is not on the network: either it did not boot, or its NIC did not come
   up. Attach HDMI or a USB-UART (115200, `ttyAMA10`) to tell those apart.

2. Check the survivors can afford it. Two of three nodes hold etcd quorum, so you have no spare failure
   until the third is back.

   ```bash
   make talosctl -- -n 192.168.10.201 etcd members    # expect 3, one unreachable
   kubectl get nodes
   ```

3. Remove the stale etcd member. A reflashed node comes back with a NEW etcd identity, and the old member
   entry at the same peer URL blocks a clean join. Takes the member ID, not the hostname.

   ```bash
   make talosctl -- -n 192.168.10.201 etcd remove-member f54813b437fd8f2e
   make talosctl -- -n 192.168.10.201 etcd members    # expect 2
   ```

4. Reflash and boot it. `make flash-talos-nvme` and pick that node, then power on with no SD card. It comes up in maintenance
   mode, which answers `--insecure` and rejects a secure call with an unknown-CA error:

   ```bash
   make talosctl -- -n 192.168.10.203 version --insecure
   ```

5. Apply that node's machine config. `03c` re-renders from the durable `secrets/secrets.yaml`, so PKI is
   preserved. Give it a hostname and it applies to that node alone and skips the etcd bootstrap:

   ```bash
   make add-node NODE=talos-cp3
   ```

   Only the apply and its two waits narrow to the one node. certSANs and the `secrets/talosconfig` endpoints
   still come from every control-plane node in `inventory.yaml`, or the rejoined node would trust an apiserver cert naming
   just itself and `talosctl` would forget the other two.

   Expect `Applied configuration without a reboot`, then the node ready. It joins etcd by itself; control
   plane nodes auto-join when a cluster already exists.

   ```bash
   make talosctl -- -n 192.168.10.201 etcd members    # expect 3, new ID for the replaced node
   kubectl uncordon talos-cp3                         # if it came back cordoned
   ```

   If the node object is stuck on a stale identity, `kubectl delete node talos-cp3` and let the kubelet
   re-register.

6. Reconcile the storage layer, if it keeps per-node records. This is where this repo stops. A reflash makes a
   fresh filesystem, so a driver that recorded the old one is holding an identifier that no longer matches,
   and it will refuse the disk rather than risk using the wrong one. The node itself reports `Ready`, so this
   hides unless you go looking. Whatever deploys your storage layer owns this step.

7. Verify everything converged.

   ```bash
   kubectl get nodes                                       # 3 Ready, no out-of-service taint
   make talosctl -- -n 192.168.10.201 etcd members         # 3 members
   kubectl get pods -A | grep -Ev 'Running|Completed'      # empty
   ```

   Pods left in phase `Failed` by the outage are cruft that nothing garbage-collects. `recover_node.sh` counts
   them for you at the end:

   ```bash
   kubectl delete pods -A --field-selector=status.phase=Failed
   ```

## Retiring a node for good

When it is not coming back, tell all three layers, in this order:

```bash
make talosctl -- -n 192.168.10.201 etcd members             # find the ID
make talosctl -- -n 192.168.10.201 etcd remove-member <id>  # etcd
kubectl delete node talos-cp3                               # kubernetes
```

Then remove its entry from `inventory.yaml`, so `03a` to `03e` stop targeting it.

What this costs, on a 3-node cluster:

- etcd drops to 2 members, which still needs 2 for quorum. No fault tolerance at all until you add a node.
- Any workload pinned one-per-node by hard anti-affinity permanently drops to 2 of 3, so it has no spare
  either. It still serves; it does not tolerate another loss.
- Replicated volumes lose their spare node. The next node failure leaves them degraded with nowhere to
  rebuild onto.
- The control-plane VIP fails over on its own, no action.

Two nodes is not a supported steady state here. Treat it as a countdown, not a configuration.

## What self-heals, and what does not

| Layer | Self-heals a machine LOSS | Self-heals a machine REPLACEMENT |
|---|---|---|
| etcd membership | yes, quorum holds on 2 of 3 | no: nothing prunes a member whose node was replaced |
| Machine config | n/a | no: `make add-node` re-applies it from the preserved PKI |
| Kubelet registration | yes | yes, once the config lands |
| Control-plane VIP | yes, Talos fails it over | yes |
| Anything above the kubelet | not this repo's to say | not this repo's to say |

What would improve it, in order:

1. **A 4th machine.** Every "serves on 2 of 3, no spare" case becomes a full recovery, because a displaced
   copy would have somewhere to go under hard anti-affinity.
2. **Nothing else.** The one manual record left is an artifact of reflashing a machine under the same name,
   it is handled by one idempotent script, and it is not on the availability path.
