# Renovate (automatic dependency updates)

Renovate opens PRs to bump every pinned dependency in the repo.

- Config: [`/renovate.json5`](../renovate.json5)
- Runner: [`.github/workflows/renovate.yaml`](../.github/workflows/renovate.yaml)
- Gate: [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml) validates every PR (shellcheck, yamllint,
  actionlint, kubeconform, renovate-config-validator) and the automerge waits on it. See "How the automerge
  works".

## Why Renovate, not Dependabot

Dependabot cannot touch image tags inside a plain Kubernetes manifest or the version vars in `versions.env`.
It would cover GitHub Actions only. Renovate covers everything this repo pins:

| Manager | Covers |
|---|---|
| `github-actions` | the workflow's own action pins, kept digest-pinned |
| regex, annotated | anything carrying `# renovate: datasource=...`: the `lib/k8s/` manifest images, shell-script image literals, and the Talos/Kubernetes recipe in `versions.env` |

The pin is the single source of truth. Versions are never restated in prose or comments, so a bump cannot strand
a stale number. A version literal survives in a doc only when that exact version is the point: a minimum, a
ceiling, or a must-match constraint.

## Running it

Self-hosted GitHub Action, cron every 3 hours plus `workflow_dispatch`.

One-time setup:

1. Create a PAT. Fine-grained: this repo, Contents + Pull requests + Workflows + Issues read-write. Or classic:
   `repo` + `workflow`.
2. Add it as the repo secret `RENOVATE_TOKEN`.
3. Trigger the workflow by hand. It populates the dependency-dashboard issue and opens the first PRs.

The built-in `GITHUB_TOKEN` cannot open PRs that re-trigger workflows and lacks the scope, so the dedicated PAT
is required. Issues read-write is what lets Renovate create and maintain the dashboard issue.

## PR grouping, and when Renovate self-merges

- One combined, auto-merged PR for every non-major update: `minor`, `patch`, `digest`, `pin` and lockfile bumps
  all land in a single "all non-major dependencies" PR that Renovate merges itself.
- Each major update is its own PR, left for review. A breaking bump is never bundled or automerged.

### How the automerge works

`platformAutomerge: false`, so Renovate merges through the API itself rather than using GitHub's native
auto-merge. It merges only once CI is green, because Renovate waits on a PR's status checks by default.
That default is the ONLY gate: `main` has no branch protection and no rulesets, so nothing enforces the
checks on the merge call itself.

Consequence: the combined PR merges on a LATER run once CI is green, roughly 2h+ after it was opened, one merge
per run. That two-pass timing is why the cron runs every 3 hours. A weekly cron would leave a green,
auto-mergeable PR sitting for a week. A manual `workflow_dispatch` also completes a pending merge on demand.

**Optional hardening, not currently applied.** To make the CI checks binding rather than advisory, require
them on `main`. Run it once, after the checks have run at least once (open a PR first, so GitHub registers
the contexts). Require checks, never reviews: a required review would deadlock Renovate, which cannot approve
its own PR. `enforce_admins` stays off so a break-glass fix can still land.

```bash
gh api -X PUT repos/yama6a/talos-raspberry-pi5-cluster/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "checks": [
    {"context": "shell"}, {"context": "yaml"}, {"context": "renovate-config"}
  ]},
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

The contexts are the CI job NAMES, so renaming a job means updating this too.

### The risk, and how to dial it back

Nothing in this repo applies itself, without exception. A merged bump changes a pinned string and no more:
`TALOS_IMAGE_RELEASE` and `KUBERNETES_VERSION` take effect when you run `make upgrade-talos` /
`make upgrade-k8s`, the `nic-keeper` image when you run `make harden-nics`, and a fresh drive needs
`make flash-talos-nvme`. So automerge here is a "newer version exists" signal, not a deployment.

Two things still need care:

- `KUBERNETES_VERSION` is capped by the pinned Talos release's own k8s default, so move it WITH Talos, never
  ahead of it. `make upgrade-k8s` rejects a version the running Talos will not serve.
- The `nic-keeper` image in `lib/k8s/` is the one pin that describes something running on the cluster. A
  merged bump still changes only a string: `make harden-nics` is what applies it.

Accepted hands-off trade-off. To de-risk without splitting the PR: add `minimumReleaseAge` (e.g. `"3 days"`) so
bumps bake before they are eligible, or drop `automerge` from the specific deps you want to gate.

## Gotchas baked into the config

- The Talos image is ONE pin, `TALOS_IMAGE_RELEASE`, tracking releases of
  [yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5). Its `-<build revision>` suffix
  would read as a semver prerelease and be skipped as unstable, so its annotation carries a custom
  `versioning=regex:` that treats the revision as a 4th component. `common.sh` derives `TALOS_VERSION` from it,
  and the kernel, pkgs and overlay pins live in that repo. See [03_operating_system.md](03_operating_system.md).
