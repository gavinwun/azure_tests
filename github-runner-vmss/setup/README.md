# `setup/` — one-shot bootstrap & teardown

Scripted equivalents of the manual "Setup order matters" steps in
[`../README.md`](../README.md). Use these for a personal test subscription
or a fresh client subscription instead of pasting the individual `az`
blocks by hand.

| Script | Does |
|---|---|
| `bootstrap.sh` | Creates every pre-Terraform resource: resource groups, the RBAC Key Vault, the tfstate storage account + container, the VMSS SSH key pair (into Key Vault), and the **three Azure AD app registrations** (`gh-runner-token-refresh`, `gh-runner-vmss-terraform-deploy`, `gh-runner-queue-poller`) with their federated credentials and role assignments. Optionally sets the GitHub repo variables/secrets and seeds the `github-app-token` secret. |
| `teardown.sh` | Reverses it — deletes the app registrations (and their SPs / federated creds / role assignments) and the Key Vault secrets. Destructive extras (tfstate account, Key Vault, created resource groups, GitHub config) are opt-in flags. |
| `lib.sh` | Shared helpers. Not run directly. |
| `state.env` | Written by `bootstrap.sh`, read by `teardown.sh`. Git-ignored. Records created app IDs and the generated tfstate account name so re-runs are idempotent and teardown removes exactly what was made. |

## Requirements

- **bash** — Git Bash, WSL, or Azure Cloud Shell (not PowerShell).
- **az** — logged in (`az login`) as a user with **Owner** or
  **User Access Administrator** on the target subscription (role
  assignments are created), plus rights to create app registrations in
  the tenant.
- **gh** *(only for `--set-github`)* — logged in with admin on the repo.
- **openssl** + **jq** *(only for `--seed-token`)*.

## What it can't do

Creating the **GitHub App itself** (README step 1) and granting its
org-installation permissions is a web-UI flow with no CLI. Do that first,
then pass `--github-app-id` / `--github-app-private-key-file` so the
scripts can wire up the repo secret and (with `--seed-token`) mint the
first installation token.

## Usage

Names (`key_vault_name`, `resource_group_name`, `vnet_resource_group_name`,
`manage_network`, `environment`, `github_org`) are read from
`../terraform/terraform.tfvars`. Only the subscription is required.

```bash
cd github-runner-vmss/setup

# See exactly what would happen - no changes:
./bootstrap.sh --subscription-id <SUB_ID> --dry-run

# Full run, including GitHub repo vars/secrets and seeding the KV token:
./bootstrap.sh \
  --subscription-id <SUB_ID> \
  --location australiaeast \
  --github-app-id <APP_ID> \
  --github-app-private-key-file ../homelabrunnergav01.2026-08-27.private-key.pem \
  --set-github --seed-token --with-poller
```

Re-running is safe: anything that already exists is detected and skipped.

### The `production` deployment environment

With `--set-github`, `bootstrap.sh` creates the `production` environment
(README step 7.5) as a **bare** environment — no protection rules, so the
`apply` job runs automatically on merge to `main`.

Add `--env-require-self-review` to also register **you** as a required
reviewer, so every `apply` pauses for your manual approval:

```bash
./bootstrap.sh --subscription-id <SUB_ID> \
  --github-app-id <APP_ID> \
  --github-app-private-key-file ../<app>.private-key.pem \
  --set-github --env-require-self-review
```

Equivalent by hand, without re-running bootstrap:

```bash
# bare environment
gh api --method PUT repos/<owner>/<repo>/environments/production

# with yourself as required reviewer
gh api --method PUT repos/<owner>/<repo>/environments/production \
  --input - <<< "{\"reviewers\":[{\"type\":\"User\",\"id\":$(gh api user --jq .id)}]}"
```

The environment is optional. If you skip it entirely, drop the
`tf-deploy-production-env` federated credential too — it's only used when
the environment gate is active.

### Runner scope (org vs repo)

`--runner-scope auto` (default) checks whether the repo owner is a user or
an organisation: a **personal account** gets `repo` (single-repo runners —
it has no org-level runners), an **org** gets `org`. Pass
`--runner-scope org|repo` to force it. With `--set-github` this is written
to the `RUNNER_SCOPE` repo variable; you still edit
`terraform/scripts/bootstrap_agent.sh` (`GITHUB_SCOPE` / `GITHUB_REPO`)
and `terraform.tfvars` (`github_runner_scope` / `github_repo`) to match,
and the GitHub App permission in README step 1 depends on it (Organization
→ Self-hosted runners for `org`; Repository → Administration for `repo`).

### Federated-credential subject format

Repos created after 2026-07-15 (or opted in) issue *immutable* OIDC
subjects — `repo:<org>@<ownerId>/<repo>@<repoId>:…`. `bootstrap.sh`
defaults to `--subject-format auto`, which creates **both** the plain and
the immutable credential for each subject, so login matches whichever
GitHub sends. `auto` needs the numeric IDs — install `gh` and
`gh auth login`, or the script falls back to plain-only (fine for older
repos, breaks login on immutable-subject repos).

## Teardown

```bash
# Safe default - just the app registrations + KV secrets:
./teardown.sh --dry-run
./teardown.sh

# Nuke everything this repo created, to start completely fresh:
./teardown.sh --all --yes
```

Run `terraform destroy` **first** if you have live infrastructure —
`teardown.sh` deliberately never touches Terraform-managed resources
(the VMSS, the bootstrap-script storage account, private endpoints, or a
`manage_network = true` VNet). Destructive flags:

| Flag | Effect |
|---|---|
| `--delete-state` | Delete the tfstate storage account — **Terraform state is lost**. |
| `--delete-keyvault` | Delete **and purge** the Key Vault. |
| `--delete-groups` | Delete resource groups `bootstrap.sh` created (from `state.env`). The management / Key Vault RGs are never auto-deleted. |
| `--reset-github` | Remove the repo variables/secrets and the `production` environment. |
| `--all` | All of the above. |

After `--delete-state`, also clear the local backend:
`rm -rf ../terraform/.terraform ../terraform/.terraform.lock.hcl`.
