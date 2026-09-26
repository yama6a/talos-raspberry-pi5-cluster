# Renovate

Renovate opens PRs that bump every pinned dependency in the repo. Setup is in the
[Renovate runbook](runbooks/06_renovate.md).

- Config: [`renovate.json5`](../renovate.json5), which extends the shared preset `github>yama6a/gha:default.json5`.
- Runner: [`.github/workflows/renovate.yaml`](../.github/workflows/renovate.yaml), daily at 05:13 UTC, plus
  `workflow_dispatch`.
- Gate: [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml). Its `shell`, `yaml` and `renovate-config` jobs
  are required checks on `main`, set by `scripts/repo-settings.sh` in `yama6a/gha`.

## Why Renovate, not Dependabot

Dependabot cannot bump an image tag in a plain Kubernetes manifest or a version variable in `versions.env`. It would
cover GitHub Actions only.

| Manager | Covers |
|---|---|
| `github-actions` | the workflows' action pins, kept pinned to digests |
| regex, annotated | anything with a `# renovate: datasource=...` comment: the `lib/k8s/` image, image literals in the shell scripts, and the Talos and Kubernetes pins in `versions.env` |

The pin is the single source of truth. Docs and comments never restate a version, so a bump cannot leave a stale
number behind. A version appears in prose only as a floor or ceiling on future bumps.

## What merges without review

| Update | PR | Merge |
|---|---|---|
| minor, patch, digest, pin, lockfile | one combined "all non-major dependencies" PR | GitHub's auto-merge, once the required checks pass |
| major | its own PR, labelled `dep-major` | a Copilot backward-compatibility check runs, and a `SAFE` verdict turns on auto-merge |
| replacement | its own PR, labelled `dep-swap` | same as a major |

## The risk

Nothing in this repo applies itself. A merged bump only changes a pinned string:

- `TALOS_IMAGE_RELEASE` takes effect with `make upgrade-talos`, and on a fresh drive with `make flash-talos-nvme`.
- `KUBERNETES_VERSION` takes effect with `make upgrade-k8s`. Move it with Talos, never ahead: `upgrade-k8s`
  rejects a version the running Talos does not serve.
- The `nic-keeper` image takes effect with `make harden-nics`.

So auto-merge here signals that a newer version exists. It deploys nothing. To reduce the risk anyway, add
`minimumReleaseAge` so bumps wait a few days, or drop `automerge` from the dependencies you want to gate.

## Gotcha in the config

`TALOS_IMAGE_RELEASE` tracks releases of [yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5)
as `<talos version>-<build revision>`. Renovate would read the `-<build revision>` suffix as a semver prerelease
and skip it as unstable. So its annotation carries a `versioning=regex:` that treats the revision as a 4th
component.
