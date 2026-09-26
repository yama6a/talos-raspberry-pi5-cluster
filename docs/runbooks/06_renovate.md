# Renovate runbook

The reasons behind this setup are in [06_renovate.md](../06_renovate.md).

## One-time setup

1. Create a personal access token for Renovate:
   - Fine-grained: this repo, with Contents, Pull requests, Workflows and Issues set to read-write.
   - Or classic: `repo` and `workflow`.

   The built-in `GITHUB_TOKEN` cannot open PRs that trigger workflows. Issues read-write lets Renovate keep its
   dependency dashboard issue.
2. Add it as the repo secret `RENOVATE_TOKEN`.
3. Run the Renovate workflow by hand from the Actions tab. It creates the dashboard issue and opens the first PRs.

Branch protection and the required checks come from `scripts/repo-settings.sh` in `yama6a/gha`. A renamed CI job
must be renamed there too, or `main` loses that check.

## Run it on demand

Run the Renovate workflow from the Actions tab. Set `dryRun` to plan without opening PRs, and `logLevel` to
`debug` to see why a dependency is skipped.
