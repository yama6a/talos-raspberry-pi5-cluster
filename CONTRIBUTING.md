# Contributing

Conventions that span this repo.

This repo stops at a configured Talos cluster with a working `kubeconfig`. Anything that runs on the cluster
belongs with that cluster's platform. The one exception is the `nic-keeper` DaemonSet. It is a Pi 5 hardware fix,
so `03d` applies it from here.

## Repository layout

| Path | Holds |
|---|---|
| `lib/shell/` | every bootstrap script (`NN_name.sh`, plus the `DANGEROUS_*` orchestrators) and the shared `common.sh` |
| `lib/k8s/` | `nic-keeper.yaml`, the one manifest this repo applies |
| `lib/talos/` | Image Factory schematics for node types without a custom build |
| `docs/` | one decision doc per step (`NN_name.md`) |
| `docs/runbooks/` | the procedures, one per decision doc, same `NN_name.md` |
| `Makefile` | a thin dispatcher over `lib/shell/`. `make help` lists every target |
| `versions.env` | committed. The Talos image release and Kubernetes pins, bumped by Renovate |
| `inventory.yaml` | gitignored. One entry per node. `inventory.example.yaml` is the template |
| `.env` | gitignored. Per-deployment config and secrets. `.env.example` is the template |
| `secrets/` | cluster credentials written by `03c`. A symlink to an off-repo store, never committed |

Run the steps in order: `02_raspi_eeprom`, then `03a` to `03g`. Use the Makefile, or run
`bash lib/shell/NN_name.sh` by hand.

## Where a value lives

| Kind of value | Lives in |
|---|---|
| The Talos image release and Kubernetes version | `versions.env`, committed |
| The node list: role, hardware type and image source per node | `inventory.yaml`, gitignored |
| Per-deployment scalars (cluster name, VIP, sizing) and secrets | `.env`, gitignored |
| Fixed identifiers that are not per-deployment config (the Pi 5 NIC, the Talos API port) | constants in `lib/shell/common.sh` |
| Internals used by one script (its own check expectations, asset filenames) | that script |

- `.env` is plain `KEY=value` only: no logic, arrays or command substitution. `common.sh` derives everything else.
- The node list needs structure, so it is YAML in `inventory.yaml`, not `.env`.
- Secrets come from `.env` and are never prompted for. `common.sh` defaults each key, so an older `.env` does not
  trip `set -u`.

## Bootstrap scripts

- Output helpers come from `common.sh`: `say`, `die`, `warn`, `ok` and `bad`. Scripts also use the `PASS` and
  `FAIL` counters, a trailing `summary`, and a non-zero exit on any failure.
- Idempotent and safe to re-run. Re-running after a partial failure is the normal recovery path.
- Script-local tunables go in a `# ---- knobs ----` block near the top, as plain assignments. No
  `${VAR:-default}` env overrides: to change a value, edit it.
- The PASS/FAIL scripts use `set -uo pipefail` without `-e`, so every check runs and the summary is complete.
  One-shot scripts that should stop at the first error use `-euo`.
- Talos tooling runs in Docker (`talosctl()` in `common.sh`), because the macOS build is unreliable.
- A `DANGEROUS_` prefix marks anything that wipes or resets state, so nobody runs it by reflex.
- Never write a tracked YAML file with `yq -i`. It rewrites the whole document and drops the blank line before a
  comment block, so even a no-op write leaves the file dirty. `yq` is fine for reads.

## The one manifest this repo applies

`lib/k8s/nic-keeper.yaml` works around the Pi 5 `macb` NIC wedge at runtime. `03d` is the machine-config half of
the same fix and applies both, so they land together and before any CNI.

- Plain manifests, no templating and no packaging. The loop script's tunables are plain assignments in its
  `# ---- knobs ----` block.
- Nothing reconciles it. A Renovate bump of the image only changes a string until someone runs
  `make harden-nics`, the same as `TALOS_IMAGE_RELEASE` and `make upgrade-talos`.

## Docs

| Kind of fact | Goes in |
|---|---|
| A decision, a trade-off, why a part or setting was picked | `docs/NN_name.md`, as fragments, bullets and tables |
| An operator procedure | `docs/runbooks/NN_name.md`, as numbered steps |
| How one line of code works, when the code does not show it | a comment on that line |

- Each fact lives in one place. A doc links a file rather than repeating its comments.
- State the current reason, never the history. This repo rolls forward.
- Never restate a version number. Point at `versions.env` instead.
- `.env.example` is the API, so every tunable knob gets one aligned trailing comment.
