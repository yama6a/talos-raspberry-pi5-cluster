# Worker nodes runbook

The reasons behind these steps are in [04_worker_nodes.md](../04_worker_nodes.md).

## Add a worker

1. Add the node to `inventory.yaml`. Read its install disk in maintenance mode:

   ```bash
   make talosctl -- -n <ip> get disks --insecure
   ```

2. Flash its drive. Pick the node from the list, or pass `NODE=<host>`:

   ```bash
   make flash-talos-nvme
   ```

3. Boot it into maintenance mode, then join it. It joins schedulable:

   ```bash
   make add-node NODE=<host>
   ```

4. Check: `kubectl get nodes` shows it `Ready` once a CNI runs.

A full `make bootstrap-cluster` needs neither step 2 nor 3 for a worker already in the inventory. `03c` brings up
every node in one pass, control-plane nodes first.

Before the first node of a new architecture joins, check that every running image has a build for it.

## Set up the x86 BIOS

The NVMe arrives with Talos already on it, so there is no boot medium to prioritise.

1. Apply the factory defaults and exit.
2. Boot order: the M.2 NVMe first, in UEFI mode. Turn off Fast Boot.
3. Secure Boot: off. Stock Talos images are not signed with a key OEM firmware trusts.
4. After power loss: On. A headless node must come back by itself.
5. Leave the TPM on. It does nothing unless you turn on disk encryption.

## Change the x86 schematic

A schematic change gives a new schematic id and a new installer ref. `talosctl upgrade` installs an image but
never rewrites the stored `machine.install.image`, so reapply first:

```bash
make reapply-talos-config NODE=<x86-host>
make upgrade-talos
```

Without the reapply, the node keeps the old ref, and a later recovery reinstalls it without the change.
`make upgrade-talos` walks every node and reboots each one whose image differs from `versions.env`.

## Make a large node score like a small one

Only if a large node takes too big a share of the pods. Advertise less than the hardware has:

```yaml
machine:
  kubelet:
    extraConfig:
      systemReserved: {cpu: 8000m, memory: 23Gi}   # a 12-core/32Gi node scores like a 4-core/7.5Gi one
```

Apply it to that node with `talosctl patch mc --mode no-reboot`.

`enforceNodeAllocatable` stays at `["pods"]`, so this changes only what the scheduler sees. Nothing is
OOM-killed for it. The kubelet restarts, the node does not.
