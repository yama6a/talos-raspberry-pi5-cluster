# Contributing

Conventions that span this repo. Anything specific to one step lives in that step's `docs/NN_*.md`, which is
where a decision or trade-off belongs, not in a code comment and not here.

This repo stops at a configured Talos cluster with a working `kubeconfig`. Anything that runs *on* the cluster
belongs wherever that cluster's platform is defined, with one exception: the `nic-keeper` DaemonSet, which is
a Pi 5 hardware mitigation and so is applied from here, by `03d`.

## Repository layout

| Path | Holds |
|---|---|
| `lib/shell/` | every bootstrap script (`NN_name.sh`, plus the `DANGEROUS_*` orchestrators) and the shared `common.sh` |
| `lib/k8s/` | the one manifest this repo applies, see below |
| `lib/talos/` | Image Factory schematics for node types without a custom build |
| `docs/` | the narrative and decision record per step (`NN_name.md`) |
| `Makefile` | a thin dispatcher over `lib/shell/`. `make help` lists every target |
| `versions.env` | committed. The Talos image release and Kubernetes pins, renovate-managed |
| `inventory.yaml` | gitignored. One entry per node. `inventory.example.yaml` is the template |
| `.env` | gitignored. Per-deployment config + secrets. `.env.example` is the template |
| `secrets/` | cluster credentials written by `03c`. A symlink to an off-repo store, never committed |

Run the steps in order: `02_raspi_eeprom`, then `03a` to `03g`. Either by hand
(`bash lib/shell/NN_name.sh`) or via the Makefile.

## Where a value lives

| Kind of value | Lives in |
|---|---|
| The Talos image release and Kubernetes version | `versions.env`, committed |
| The node list: per-node role, hardware type and image source | `inventory.yaml`, gitignored |
| Per-deployment scalars (cluster name, VIP, sizing) and secrets | `.env`, gitignored |
| Fixed identifiers that are not per-deployment config (the Pi 5 NIC and disk, the Talos API port) | constants in `lib/shell/common.sh` |
| Internals used by one script (its own check expectations, asset filenames) | that script |

`.env` is plain `KEY=value` only: no logic, arrays or command substitution. Anything derived is derived in
`common.sh`. Node topology outgrew that, which is why it is a separate YAML file. Secrets are read from `.env`,
never prompted; `common.sh` defaults each to empty so an older `.env` does not trip `set -u`.

## Bootstrap scripts

- UX contract from `common.sh`: `say`/`die`/`warn`/`ok`/`bad`, `PASS`/`FAIL` counters, a trailing `summary`,
  non-zero exit on any failure.
- Idempotent and re-run-safe. Re-running after a partial failure is the normal recovery path.
- A `# ---- knobs ----` block near the top for script-local tunables, as plain assignments. No
  `${VAR:-default}` env overrides: to change a value, edit it.
- `set -uo pipefail`, deliberately not `-e` in the PASS/FAIL scripts so checks accumulate and report a full
  summary. One-shot scripts that should abort early use `-euo`.
- Talos tooling runs in Docker (`talosctl()` in `common.sh`), because the macOS build is unreliable.
- A `DANGEROUS_` prefix on anything that wipes or resets state, so it cannot be run by reflex.

### `common.sh`

Sourced by every script. It self-locates the repo root, loads `versions.env` then `.env`, derives what a flat
file cannot express, parses `inventory.yaml` into the per-role arrays, resolves a node's image with
`installer_ref_for` / `factory_schematic_id`, and provides the output helpers, `require`, `use_kubeconfig`, the
dockerized `talosctl`, and `step`/`run_step`.

**Never write a tracked YAML file with `yq -i`.** It rewrites the whole document and drops the blank line
before a comment block, so even a no-op write leaves the file dirty. `yq` is fine for reads.

## The one manifest this repo applies

`lib/k8s/nic-keeper.yaml` is the only Kubernetes object here, because it is the only one that is purely a
property of this hardware: it mitigates the Pi 5 `macb` NIC wedge at runtime, and `03d` is the machine-config
half of the same mitigation. `03d` applies it, so both halves land together and before any CNI.

Plain manifests, no templating and no packaging. The loop script's tunables are plain assignments in its
`# ---- knobs ----` block, following the same rule as the shell scripts: to change a value, edit it.

Applying it is not self-healing. Nothing here reconciles, so a Renovate bump of the image is a changed string
until someone runs `make harden-nics`. That is the same contract as `TALOS_IMAGE_RELEASE`.

## Reaching past the cluster

Two `.env` keys let the cluster's own workloads take part in node lifecycle, without this repo naming them:

| Key | Used by | Contract |
|---|---|---|
| `PRE_DRAIN_HEALTH_HOOK` | `03e`, before draining each node | any command; exit 0 when replicated stores are in sync. Gets `NODE` and `REPLICATION_HEALTH_TIMEOUT` in its environment |
| `REBALANCE_SKIP_NAMESPACES` | `03g` | space-separated namespaces to leave alone |

Both default to empty, and empty means the step proceeds without that protection. `03e` warns when it does,
because on a cluster with replicated storage that is a real risk rather than a no-op.

## Docs

`docs/NN_*.md` is where the why lives. Fragments, bullets and tables over paragraphs. State the current reason,
not the history: this repo rolls forward, so "what it used to be" is dead weight that also goes stale.

Comments are the exception, not the habit: write one when the reason is not derivable from the code, keep it
short, and attach it to the exact line. `.env.example` is the API, so every tunable knob gets one aligned
trailing comment.
