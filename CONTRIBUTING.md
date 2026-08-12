# Contributing

Conventions that span this repo. Anything specific to one step lives in that step's `docs/NN_*.md`, which is
where a decision or trade-off belongs, not in a code comment and not here.

This repo stops at a configured Talos cluster with a working `kubeconfig`. Anything that runs *on* the cluster
belongs in [offgrid](https://github.com/yama6a/offgrid), with two exceptions: the `nic-keeper` and `coredns`
charts, which are hardware- and OS-specific and are published from here for that repo to deliver.

## Repository layout

| Path | Holds |
|---|---|
| `lib/shell/` | every bootstrap script (`NN_name.sh`, plus the `DANGEROUS_*` orchestrators) and the shared `common.sh` |
| `lib/talos/` | Image Factory schematics for node types without a custom build |
| `docs/` | the narrative and decision record per step (`NN_name.md`) |
| `charts/` | the two charts published to `ghcr.io`, see below |
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

## The two published charts

`charts/nic-keeper` and `charts/coredns` are the only Kubernetes objects this repo owns, because both are
specific to this hardware and OS: nic-keeper selects `node.kubernetes.io/instance-type: rpi5` (stamped by `03c`
from each node's inventory `type`), and coredns patches a Deployment Talos itself creates.

They are published to `oci://ghcr.io/yama6a/charts` by `.github/workflows/publish-charts.yaml`, on merge to
`main`. It publishes a chart only when its version is not already in the registry, so unrelated commits are
no-ops. There is no tag to cut and no GitHub Release: the registry is the distribution channel, and Renovate
resolves updates from its tag list.

**Their `version:` is NOT inert.** Unlike a wrapper chart, these are published artifacts. Bump the version in
the same PR that changes the chart: the `chart-version` CI job fails otherwise, because publish-charts would
silently skip the change rather than overwrite a published version.

## The cross-layer exception

`03e_talos_upgrade.sh` names Longhorn, CNPG and RabbitMQ, and `recover_node.sh` talks to the `longhorn.io` API.
That is a deliberate exception to the repo boundary, not an oversight: those are the workloads that hang a drain
or fail to rejoin, and a node lifecycle operation cannot be correct without knowing about them. If you run a
different storage layer, those two scripts are what you edit.

## Docs

`docs/NN_*.md` is where the why lives. Fragments, bullets and tables over paragraphs. State the current reason,
not the history: this repo rolls forward, so "what it used to be" is dead weight that also goes stale.

Comments are the exception, not the habit: write one when the reason is not derivable from the code, keep it
short, and attach it to the exact line. `values.yaml` and `.env.example` are the API, so every tunable knob gets
one aligned trailing comment.
