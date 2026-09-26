# Losing and replacing a node

What breaks when one of the three Pis goes away, what comes back by itself, and what needs hands. This covers the
machine layer only. What the workloads do about a node loss is their own business. Procedures are in the
[node recovery runbook](runbooks/05_node_recovery.md).

## Losing a machine vs replacing one

- **A lost machine** is a scheduling problem, as long as the volumes belong to a replicated storage layer. The pod
  reattaches its volume on a survivor and starts. Nothing to delete or restore.
- **A replaced machine** that comes back under the same name, reflashed, needs hands. Some records outlive the
  disk they describe:

| Record | Why it does not heal by itself | Whose job |
|---|---|---|
| the node's etcd member | a reflashed node has a new etcd identity, and the old member at the same peer URL blocks the join | this repo, `make recover-node` |
| per-node records a storage layer keeps | a driver that stamped the old filesystem holds an ID the fresh one does not match | the platform, after this repo |

`make recover-node NODE=<host>` handles the first and stops at a Ready, uncordoned, untainted node. A worker has
no etcd member, so the script skips that phase for a node whose `role` is `worker`.

## The out-of-service taint

Kubernetes waits about six minutes before it hands a silent node's volumes to another node, in case the node is
still alive and writing. `node.kubernetes.io/out-of-service:NoExecute` skips that wait: it asserts the machine is
gone, and Kubernetes force-deletes its pods and releases their volumes at once.

- **This repo never sets it.** Only an operator, or something watching the cluster, can make that call.
- **This repo clears it**, in `03e` and in `recover_node.sh`, next to their `uncordon`. A node that keeps the
  taint accepts no pods, and whatever set it may no longer be running.

Rules for anything that sets the taint automatically:

- Never on a Ready node. That protects an ordinary drain: `kubectl drain` and `03e` cordon a machine that is
  still up.
- A cordon alone is not a reason to skip, because `talosctl reset` cordons a machine that never comes back.
- A Pi 5 Talos reboot is back in about 90s, shorter than Kubernetes' NotReady delay plus a sane grace period. So a
  reboot never triggers it, and a rolling upgrade is unaffected.

## Retiring a node for good

On a 3-node cluster, running on 2 costs this:

- etcd has 2 members and still needs 2 for quorum. No fault tolerance at all until you add a node.
- A workload pinned one per node by hard anti-affinity drops to 2 of 3. It still serves but survives no further
  loss.
- Replicated volumes have no spare node. The next failure leaves them degraded, with nowhere to rebuild.
- The control-plane VIP moves to a survivor by itself.

Two nodes is not a supported steady state. Treat it as a countdown, not a configuration.

## What heals by itself

| Layer | After a machine loss | After a machine replacement |
|---|---|---|
| etcd membership | yes, quorum holds on 2 of 3 | no, nothing prunes the old member |
| Machine config | n/a | no, `make add-node` applies it again from the kept PKI |
| Kubelet registration | yes | yes, once the config lands |
| Control-plane VIP | yes, Talos moves it | yes |
| Anything above the kubelet | not this repo's to say | not this repo's to say |

A 4th machine is the one improvement left. A displaced copy would then have somewhere to go under hard
anti-affinity, so every "serves on 2 of 3, no spare" case would fully recover.
