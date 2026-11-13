# acse-tenant

The Terraform module and workflow template behind an ACSE tenant's **setup** repository (spec 02e). You write
`config/tenant.yaml`, and one `terraform apply`, run by `acse-setup-apply.yml` on merge, builds the rest in your own AWS
account and GitHub organization:

1. **The namespace** `acse/<tenant>/`:
   - Secrets Manager secrets for the keys, as empty containers;
   - one SSM index per `tenant.yaml` section, `settings/<section>` (`settings-index-1.0`): the section inline when it
     fits, or in parts `settings/<section>/0..n-1` when it does not.
2. **The promoter's narrow role** (`cloud.workflow_role`, Outbox tenants only):
   - trusted by GitHub OIDC for `acse-promote.yml` on the outbox repository's default branch;
   - able to read exactly four entries.
3. **Three organization rulesets** that keep ACSE Change inside the naming boundary `{prefix}acse{suffix}/**`:
   - `acse-change-only-on-acse-branches` covers every other branch: no creation, update or deletion, and no force pushes;
   - `acse-change-no-force-push` covers the boundary's own branches: no force pushes. Deletion stays allowed;
   - `acse-change-no-tags` covers every tag.
4. **The setup apply's own two roles** (when you pass `setup_credential_secret_arn`):
   - `acse-setup-apply` is the only role that can read your setup App's key. It is trusted only for this workflow's
     apply job on the default branch, in the environment `acse-setup-apply`;
   - `acse-setup-plan` is for the post-merge plan. It runs with no approval gate and reads only your read-only App's
     key, so reviewers see the full GitHub and cloud plan before they approve;
   - `acse-setup-check` is for the pull request's cloud-only plan. It cannot read either key, and that job holds no
     GitHub credential at all (SC-5);
   - the setup repository's OIDC subject template is always `repo` + `context` + `job_workflow_ref` (SC-1). This
     changes the subject of every workflow in that repository.
5. **Two generated files**, both rendered from `tenant.yaml`:
   - `.github/acse-gate.json` in the policies repository (`gate-config-1.0`);
   - `.github/acse-promote.json` in the outbox repository: `promoter-config-1.0`, or `promoter-config-1.1` when
     `tenant.yaml` sets `outbox.promoter_key` (tenant-config-1.3), which is then copied into it exactly.

   ACSE never proposes either file.

Nothing in this repository holds, reads or prints a secret value. The workflow uses no GitHub secret and no GitHub
variable: its cloud access is OIDC only.

Two modes. **Self-hosted** (the default) builds all of the above in your own AWS account. **SaaS mode**
(`saas_publish_role_arn` set; spec 02e Amendment 6) is for tenants whose runtime InitValue hosts: the namespace lives in
InitValue's AWS runtime account, and the module publishes into it write-only. See [SaaS mode](#saas-mode).

The namespace is on AWS in this release (OD-16). The setup App's keys can be in AWS Secrets Manager or, in either
mode, in Google Cloud Secret Manager (SA-5). Apache-2.0.

## What it creates

The exact names and file bytes for sample tenants are in [`vectors/acse-tenant-vectors-1.0.json`](vectors/acse-tenant-vectors-1.0.json). Other components pin that file.

| Entry | Name | Created by | Value written by | Read by |
|---|---|---|---|---|
| secret `github/read/private-key` | `acse/<tenant>/github/read/private-key` | this module (container) | your pipeline | ACSE runtime |
| secret `github/change/private-key` | `acse/<tenant>/github/change/private-key` | this module (container) | your pipeline | ACSE runtime |
| secret `outbox/promoter/private-key` (Outbox) | `acse/<tenant>/outbox/promoter/private-key` | this module (container) | your pipeline | promoter, by OIDC |
| secret `evidence/seal-key/current`, `…/next` | `acse/<tenant>/evidence/seal-key/{current,next}` | this module (container) | keygen | ACSE runtime |
| secret `tfc/token` | `acse/<tenant>/tfc/token` | this module (container) | your pipeline | ACSE runtime |
| parameter `settings/<section>` (index) | `/acse/<tenant>/settings/<section>` | this module, **last** | **this module only** | runtime, promoter (`outbox`, `naming`, always inline) |
| parameter `settings/<section>/<i>` (part) | `/acse/<tenant>/settings/<section>/<i>` | this module, **before the index** | **this module only** | runtime, through the index |
| parameter `evidence/public-key` | `/acse/<tenant>/evidence/public-key` | **keygen, not this module** | keygen | promoter, you (to pin) |
| IAM role (Outbox) | `cloud.workflow_role` | this module | — | `acse-promote.yml` |
| IAM role | `acse-setup-apply` | this module | — | `acse-setup-apply.yml`'s apply job only |
| IAM role | `acse-setup-plan` | this module | — | `acse-setup-apply.yml`'s post-merge plan job only |
| secret policy | on your read-only App's key (yours, outside `acse/<tenant>/`) | this module | — | denies `GetSecretValue` to all but `acse-setup-plan` |
| IAM role | `acse-setup-check` | this module | — | `acse-setup-apply.yml`'s pull request job only |
| secret policy | on your setup App's key (yours, outside `acse/<tenant>/`) | this module | — | denies `GetSecretValue` to all but `acse-setup-apply` |
| GitHub environment | `<setup>` › `acse-setup-apply` | this module | — | default branch only; no administrator bypass; self-review prevented; at least one required reviewer |
| OIDC subject template | `<setup>` | this module | — | `[repo, context, job_workflow_ref]`, always |
| ruleset (branch) | `acse-change-only-on-acse-branches` | this module | — | ACSE readiness (layer 3) |
| ruleset (boundary) | `acse-change-no-force-push` | this module | — | ACSE readiness (`force_push_blocked`) |
| ruleset (tag) | `acse-change-no-tags` | this module | — | ACSE readiness (layer 3) |
| file | `<policies>/.github/acse-gate.json` | this module (PR or commit) | — | gate template 1.1.0 |
| file | `<outbox>/.github/acse-promote.json` | this module (PR or commit) | — | promoter template 1.1.0 |

Further rules:
- **Sections.** `settings/<section>` is published for each of `approvals`, `cloud`, `code_sources`, `delivery`,
  `gate`, `github`, `naming`, `outbox` and `repositories` that the file contains. `naming` is always published.
- **Every `settings/<section>` is an index** (`settings-index-1.0`, DEC-6). It is
  `{schema, section, commit, sha256, bytes, parts, inline}`:
  - when the whole document fits in 8192 bytes, `parts` is 0 and the section is `inline`;
  - otherwise the section's JSON is cut into `settings/<section>/0..n-1` of at most 7168 bytes each. Read the index,
    concatenate the parts in order, check `bytes` and `sha256`, and read again if they differ.

  Every index and part is an Advanced-tier `String`. Parts are written before the index. More than 64 parts for one
  section refuses to plan.
- **Secrets have no version.** This module never writes a secret value, and never reads one.
- **The promoter's role** can call `ssm:GetParameters` on `settings/outbox`, `settings/naming` and `evidence/public-key`,
  and `secretsmanager:GetSecretValue` on `outbox/promoter/private-key`. It can also call `kms:Decrypt` through
  Secrets Manager when you set `kms_key_arn`. It has nothing else.
- **The runtime's own read grant** on the namespace belongs to the ACSE runtime module. Feed it `secret_arns` and
  `parameter_arn_prefix`.

## Inputs

| Name | Default | Meaning |
|---|---|---|
| `tenant_yaml` | (required) | The text of `config/tenant.yaml`: `file("${path.root}/../config/tenant.yaml")` |
| `setup_commit` | (required) | The commit being applied. The workflow passes `github.sha` |
| `kms_key_arn` | `null` | A customer-managed key for the secrets |
| `secret_recovery_window_in_days` | `30` | The recovery window for a secret the module stops managing |
| `create_github_oidc_provider` | `false` | Create `token.actions.githubusercontent.com` in the account. It normally exists already, because the workflow uses it |
| `manage_promoter_role` | `true` | Create `cloud.workflow_role` (Outbox tenants) |
| `outbox_oidc_subject_includes_job_workflow_ref` | `false` | Bind the role to `acse-promote.yml` through the outbox's OIDC subject template |
| `optional_permissions` | `{}` | Opt-in reads ACSE's setup never requests (`aws`, `gcp`, `azure` lists), each unlocking named checks; AWS ones are granted on `aws_scanner_role_name`, GCP and Azure recorded only (DEC-49) |
| `aws_scanner_role_name` | `"ACSEReadOnlyScanner"` | The scanner role the AWS optional permissions are attached to |
| `ruleset_enforcement` | `"evaluate"` | `evaluate`, `active` or `disabled`. Switch to `active` after review; readiness passes only when the ruleset is active |
| `ruleset_repository_include` / `_exclude` | `["~ALL"]` / `[]` | The repositories the rulesets cover |
| `ruleset_bypass_integration_ids` | `[]` | Your bots' App ids, **including the App this apply uses**. Never ACSE Change |
| `ruleset_bypass_deploy_keys` | `true` | Let deploy keys bypass |
| `generated_files_mode` | `"pull_request"` | `pull_request`: open a PR when the default branch's copy differs. `direct`: commit to the default branch |
| `policies_default_branch` / `outbox_default_branch` | `null` | `outbox_default_branch` is **required** for Outbox tenants. `policies_default_branch` is read from GitHub when null |
| `commit_author` | `null` | `{name, email}` for the generated commits |
| `setup_credential_secret_arn` | `null` | Your setup App's key: a secret you name, **outside** `acse/<tenant>/`, in `cloud.account`. When set, the module creates the two setup roles, the apply environment and the secret's resource policy (DEC-20) |
| `setup_plan_credential_secret_arn` | `null` | **Required** with `setup_credential_secret_arn`. It is your read-only App's key, in a secret you name outside `acse/<tenant>/`. Only `acse-setup-plan` can read it |
| `setup_plan_role_name` / `setup_plan_policy_arns` | `"acse-setup-plan"` / ReadOnlyAccess | The post-merge plan role |
| `setup_credential_extra_reader_arns` | `[]` | Break-glass or bootstrap administrator roles that may also read the setup key. Never an ACSE role |
| `setup_apply_role_name` / `setup_check_role_name` | `"acse-setup-apply"` / `"acse-setup-check"` | The two roles' names. They must differ from each other, from `cloud.workflow_role` and from `runtime_role_arn`. The check role holds no GitHub credential and cannot read the setup key |
| `setup_apply_policy_arns` / `setup_check_policy_arns` | AdministratorAccess / ReadOnlyAccess | Broad managed policies, with no service-level lists |
| `setup_apply_environment` | `"acse-setup-apply"` | The environment the apply role requires. Keep the default: the template names it |
| `setup_apply_environment_reviewers` | none | Required reviewers (user and team ids) for every apply. **At least one is required** (SC-1); self-review is prevented and administrators cannot bypass |
| `setup_oidc_subject_repo` / `outbox_oidc_subject_repo` | `null` | The repo segment of each repository's OIDC `sub`: `owner/name`, or `owner@id/name@id` for repositories on GitHub's immutable subject format. Those are repositories created after 2026-07-15, or ones that opted in (DEC-29) |
| `setup_default_branch` | `null` | **Required** with `setup_credential_secret_arn`: a pull request's plan cannot look it up |
| `setup_credential_store` | `"aws"` | Where the setup and plan Apps' keys live: `aws` (the two secret ARNs) or `gcp` (Google Cloud Secret Manager; no AWS setup roles, see `modules/gcp-setup-credential`; SA-5) |
| `gcp_setup_project` | `null` | **Required with `gcp`, and only then:** your **dedicated** GCP setup project, which holds only the pool and the setup, plan, ACSE App and promoter keys. The apply job gets `roles/editor` and `roles/iam.securityAdmin` on it only. That it holds nothing else is your requirement; the plan cannot check it |
| `runtime_role_arn` | `null` | Only to refuse a setup role that is the runtime's |
| `saas_publish_role_arn` | `null` | **SaaS mode** when set: the per-tenant publish role in InitValue's runtime account (must be `cloud.account`). Needs a setup credential (`aws` or `gcp`), and refuses `create_github_oidc_provider` |
| `saas_publish_on_apply` | `true` | `false` only for the one-time bootstrap apply, which cannot assume the publish role |
| `saas_app_keys_version` | `null` | Change it to put new versions of the ACSE Read and Change keys. SaaS mode only |
| `saas_read_app_private_key` / `saas_change_app_private_key` | `null` | Ephemeral, sensitive: the two keys, read from your own store in the apply phase |
| `warn_unseen_gate_repositories` | `true` | Warn in the plan, never fail, when a gate repository is not visible to ACSE Read |
| `tags` | `{}` | AWS tags |

Providers: `hashicorp/aws` 6.x, set to `cloud.account` and `cloud.region`; the module refuses any other account or
region. In SaaS mode it must be signed in to your own account (the setup secret's), or need no configuration at all
when the setup credential is in Google Cloud. `integrations/github` 6.x, with `owner` set to the organization that holds the three repositories.

## Outputs

These outputs name what the module built:
- `namespace`, `boundary` and `branch_ruleset_exclude`;
- `secret_names` and `secret_arns`;
- `settings_parameter_names`, `settings_values`, `evidence_public_key_parameter_name` and `parameter_arn_prefix`;
- `oidc_provider_arn`, `promoter_role_arn`, `promoter_trust_subject`, `promoter_trust_policy`,
  `promoter_read_policy` and `promoter_store_reads`;
- `ruleset_ids`, `setup_roles`, `setup_oidc_subjects`, `gcp_setup_project` and `promoter_oidc` (what the promoter's
  WIF provider binds, with `key_in_gcp`);
- `saas`: the publish role, its policy and trust for InitValue's pipeline, the published names, and what was skipped.
- `settings_index_values`, `settings_part_names`, `settings_part_values` and `settings_payloads`.

These outputs cover the generated files:
- `generated_files` gives each file's repository, path, schema and exact content;
- `generated_file_pull_requests` lists the PRs opened for them.

## What you do by hand

ACSE cannot do these steps for you (spec 02e §6, AC-6):

1. **Create the repositories.** Create `setup`, `policies`, and `outbox` if you use Outbox. Copy
   `template/.github/workflows/acse-setup-apply.yml` into `setup` **unchanged**, and protect `setup`'s default
   branch: two approvals, CODEOWNERS over `config/` and `terraform/`, and no bypass for ACSE Change. ACSE relies on
   that protection (Amendment 1 item 1; GA-3).
2. **Create the GitHub Apps** in your organization with the permissions Setup › Access lists:
   - ACSE Read and ACSE Change;
   - the promoter App, if you use Outbox.

   Then put their ids in `tenant.yaml`.
3. **Create your setup Apps and their secrets**, once. They are yours, not ACSE's (DEC-20):
   - **the setup App** needs organization administration write (rulesets), contents and pull-request write on
     `policies` and `outbox`, and administration write on `setup` and `outbox` (environment, OIDC subject templates);
   - **the read-only App** is for the post-merge plan. It needs administration, contents, pull requests and metadata
     read on the repositories, and organization administration read for rulesets and installations. It has no write;
   - there is no App for pull requests: their check covers the cloud side only and holds no GitHub credential (SC-5).

   Put each App's key in its own Secrets Manager secret you name, in `cloud.account`, **outside `acse/<tenant>/`**.
   Copy `examples/setup-repository/.github/pull_request_template.md` into `setup`. That keeps
   it beyond the reach of every ACSE identity, because the runtime's read grant covers the namespace only. List the
   setup App in `ruleset_bypass_integration_ids`.
4. **Bootstrap once.** Copy `examples/setup-repository/terraform/` into `setup/terraform/` and fill in
   `terraform.tfvars` and `backend.{plan,apply}.hcl`. Then run the first apply yourself, as an administrator, with
   `use_web_identity = false`, your administrator role in `bootstrap_admin_role_arns`, and
   `create_github_oidc_provider = true` if the account has no GitHub OIDC provider. That apply creates:
   - `acse-setup-apply` and `acse-setup-check`;
   - the environment `acse-setup-apply`;
   - the secret policies.

   You must name at least one required reviewer in `apply_environment_reviewers`. The environment is deployable from
   the default branch only, prevents self-review, and admits no administrator bypass. For a repository on GitHub's
   immutable subject format, set `oidc_subject_repo` from `sub_claim_prefix`. The bootstrap also sets the setup
   repository's OIDC subject template, which the two roles' trusts expect. From then on, `acse-setup-apply.yml` does
   every apply.
5. **Merge `tenant.yaml`.** The workflow handles each step:
   - it checks the pull request's cloud side with `acse-setup-check`. ACSE comments on the pull request if a listed gate
     repository isn't visible to ACSE Read (Direct tenants; Outbox-only tenants see it on Setup › Access);
   - after merge, it posts the full plan with `acse-setup-plan`;
   - once the environment's reviewers approve, it applies exactly that plan with `acse-setup-apply`. **On Setup › Access this step shows as "apply
   succeeded", not as an ACSE probe:** ACSE can never read your setup key, so it cannot check that the key exists.
6. **Place the keys.** Your pipeline puts each App key, and `tfc/token` if you use Terraform Cloud, into its secret
   under `acse/<tenant>/`.
7. **Run keygen.** Keygen creates and writes the seal keys and `evidence/public-key`. Copy the fingerprint into
   `outbox.runtime_pubkey_fingerprint` by PR (T-7). The next apply republishes `settings/outbox`.
8. **Merge the generated-file PRs.** In `pull_request` mode, merge the PRs the apply opened in `policies` and `outbox`.
9. **Switch the rulesets to Active.** Review what GitHub reports they would block in Evaluate, then set
   `ruleset_enforcement = "active"`.

## The workflow template

`template/.github/workflows/acse-setup-apply.yml` has three jobs:
- `check` runs on a pull request: `terraform fmt`, `validate`, and a cloud-only plan with no GitHub credential;
- `plan` runs on a push to the default branch, with no approval gate. It uses a read-only App and posts the full
  GitHub and cloud plan to the job summary;
- `apply` needs `plan` and runs in the environment `acse-setup-apply`. It plans again with the setup App, refuses
  anything that differs from the reviewed plan, then applies.

The two jobs use two roles, and a pull request cannot reach the apply role:
- the check job runs only on `pull_request` and names no environment, so its token can assume only
  `acse-setup-check`. It holds no GitHub credential. It runs `terraform validate` and a plan of the cloud side only
  (`-target=module.acse_tenant.<r>` for each of the module's `pr_plan_targets`, so **your root must name the module
  call `acse_tenant`**). The GitHub side is planned in the apply job;
- the apply job runs only on the default branch, in the environment `acse-setup-apply`, which the apply role's trust
  requires;
- a pull request that edits the workflow to name that environment is refused by its protected-branch rule.

`tools/check_template.py` asserts this structure.

It holds no tenant value. Your `terraform/` root receives these, and only these:
- `AWS_WEB_IDENTITY_TOKEN_FILE`, a GitHub OIDC token for `sts.amazonaws.com`;
- `TF_VAR_acse_setup_phase`, which is `plan` or `apply`;
- `TF_VAR_setup_commit`;
- `-backend-config=backend.<phase>.hcl`, when that file exists.

Check warnings never fail a run. GA-4's warning on the pull request comes from ACSE itself, as a comment the
runtime posts at its next sync; the check job's summary says so. The module's own GA-4 check runs again in the
post-merge plan as a secondary signal (DEC-25).

## SaaS mode

Set `saas_publish_role_arn` to the publish role the Access page shows you (SA-3). It is not secret. Then
`tenant.yaml`'s `cloud.*` names **InitValue's** runtime account and region, where the runtime and `acse/<tenant>/`
live (SA-4). The cloud ACSE scans is a cloud connection, not `cloud.*`.

What changes:
- **Not created:** the namespace's secrets and parameters, the GitHub OIDC provider, and the promoter role (SA-6).
  InitValue's infrastructure pipeline creates them, and the publish role, per tenant (SA-2).
- **Still created:** the rulesets, the generated files, the apply environment and the setup repository's OIDC
  subject template, and the setup roles when your keys are in AWS. In SaaS mode those roles go in **your** AWS
  account (the account of `setup_credential_secret_arn`), and your AWS provider signs in there.
- **Published write-only** (SA-1). The publish role can write that tenant's `settings/*` and put a new version of the
  two App keys, and can never read anything. A Terraform parameter or secret-version resource reads its value back on
  every refresh, so none is used. Instead, on apply only, `scripts/saas-publish.sh` signs in as the publish role with
  a fresh OIDC token and:
  - puts every section's parts, then its index (`PutParameter`, Advanced, overwrite), on every apply;
  - deletes a part or index that left the configuration (`DeleteParameter`), using the slots recorded in state;
  - puts the ACSE Read and ACSE Change App keys (`PutSecretValue`) when you change `saas_app_keys_version`. Pass the
    keys as `saas_read_app_private_key` and `saas_change_app_private_key`, read ephemerally in the apply phase.

  State holds `{commit, sha256, parts}` per section and the parameter names, never a value. The plan job and the pull
  request's job never run the step, so they never assume the role. The runner needs `bash`, `curl`, `python3` and the
  AWS CLI v2, which GitHub's hosted runners have.
- **Bootstrap.** The publish role trusts only the workflow's apply job, so the one-time administrator apply sets
  `saas_publish_on_apply = false`. The workflow's first apply publishes.
- **For InitValue's pipeline:** the `saas` output renders the publish role's exact policy and trust
  (`publish_policy`, `publish_trust_policy`); the vectors carry them too.

### A setup credential in Google Cloud (SA-5): a dedicated project

Set `setup_credential_store = "gcp"` and `gcp_setup_project`, and call
[`modules/gcp-setup-credential`](modules/gcp-setup-credential) with the same project, the module's
`setup_oidc_subjects` and, for Outbox tenants, its `promoter_oidc` output.

**The project must be dedicated (Koushik, 2026-11-07: "Dedicated Project, broad roles").** It holds only:
- the workload identity pool and its providers;
- the setup App's key and the read-only plan App's key;
- in SaaS mode, the ACSE Read and Change App keys the apply puts into InitValue's namespace;
- for Outbox tenants, the **promoter App's key**.

Nothing else may be in it. The apply job gets `roles/editor` and `roles/iam.securityAdmin` on that project, and on no
other project and never organization-wide. The roles are broad, but the blast radius is one otherwise empty project.
Terraform cannot verify that the project holds nothing else, so this is your requirement: the GCP module refuses to
plan until you set `gcp_setup_project_is_dedicated = true`. It also refuses a secret that names another project.

Inside the pool, grants go to federated principals directly, with no service account:
- **The setup provider** (setup repository, audience `acse-setup-gcp`) maps the token's exact `sub`, the same SC-1
  subjects the AWS roles trust, to `attribute.acse_job`:
  - `apply` reads the setup key and the ACSE App keys;
  - `plan` reads only the read-only key;
  - `check` reads nothing;
  - anything else maps to `none`, which the provider refuses.
- **The promoter provider** (outbox repository, audience `acse-promote-gcp`) maps only `acse-promote.yml` on the
  outbox's default branch (its `sub` and `job_workflow_ref`) to `promote`. That principal reads exactly the promoter
  key: never the setup or plan key, and no project role.

In SaaS mode the promoter key therefore never goes into InitValue's namespace. The module creates no
`outbox/promoter/private-key` there, and the promoter's AWS read policy, rendered for InitValue's pipeline, grants the
three parameters only. Promoter template 1.1.0 (core) reads the key from Secret Manager through WIF, using the GCP
module's outputs:
- `promoter_workload_identity_provider`, the external_account audience;
- `promoter_key_secret_name` (`projects/<project>/secrets/<name>`);
- `promoter_audience`.

The promoter learns where its key is from `.github/acse-promote.json`. Copy the three outputs into `tenant.yaml`
(tenant-config-1.3), and the module then writes the file as `promoter-config-1.1`:

```yaml
outbox:
  promoter_key:
    store: gcp_secret_manager
    workload_identity_provider: "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/acse-setup/providers/github-promoter"
    secret_name: projects/example-acse-setup/secrets/acse-promoter-app-private-key
    audience: acse-promote-gcp
```

`store: gcp_secret_manager` is accepted only in SaaS mode with `setup_credential_store = gcp`, and the secret must be in
`gcp_setup_project`. Without `promoter_key` the file stays `promoter-config-1.0` and the plan warns
(`check.promoter_key_named_in_tenant_yaml`), because the promoter would look for its key in the namespace, where
there is none. `store: aws_namespace` names the default explicitly (the namespace key, read with
`cloud.workflow_role`) and also writes 1.1.

Template 1.1.0 of `acse-setup-apply.yml` also issues a token for audience `acse-setup-gcp`, as
`TF_VAR_acse_gcp_web_identity_token_file`. The apply job then federates twice: to Google Cloud for the keys, and to
InitValue's publish role. The full root is in [`examples/saas-gcp-setup-repository`](examples/saas-gcp-setup-repository).

## Tests

These checks run in CI (`.github/workflows/ci.yml`) and need no credentials:
- `terraform test` runs against mock providers only. The cases are in `tests/acse_tenant.tftest.hcl`, and each asserts
  the module's output equal to the vectors.
- `python3 -I tools/render_vectors.py --check`. The vectors are rendered by a second, independent implementation
  (`tools/render_vectors.py`) from `vectors/cases/*/tenant.yaml`.
- `python3 -I tools/check_template.py`. This is the AC-1 static scan of the template: no `secrets.` or `vars.`, only
  allowed expressions, actions pinned by SHA, and no tenant literal.
- The GCP module's own tests (`modules/gcp-setup-credential/tests`), against a mock provider.
- SaaS-mode runs in `tests/acse_tenant.tftest.hcl` are plan only, so the publish step never runs in CI.

## Open decisions

The defaults this module took, and the cost of changing each, are in [`docs/decisions.md`](docs/decisions.md).

## Version floor and OpenTofu

The module requires Terraform **1.10 or later** (`required_version = ">= 1.10.0"`). From 1.10 an `ephemeral` resource
can feed a provider block without its value being written to state or to the plan file. The example root reads the
setup App's key only through `ephemeral "aws_secretsmanager_secret_version"`. Below that floor the key would land in
the plan file, which is what DEC-20 exists to prevent.

**OpenTofu:** before you use it, check that your OpenTofu release accepts ephemeral values in provider blocks. This
module has not been tested on OpenTofu.

## Other clouds

The namespace is AWS only in this build (OD-16). For the setup keys:
- **GCP:** built, as `setup_credential_store = "gcp"` and `modules/gcp-setup-credential` (SA-5).
- **Azure:** the same pattern would work with Key Vault and federated credentials. It is not built.
