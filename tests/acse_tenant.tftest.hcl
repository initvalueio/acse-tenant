# The module against vectors/acse-tenant-vectors-1.0.json, with mock providers only: no AWS or GitHub credential and
# no network call to either. Each run has its own state (state_key), since the runs describe different tenants.
# Cases in the vectors file are sorted by name:
#   cases[0] direct-minimal   cases[2] outbox-and-gate   cases[3] outbox-prefixed-boundary

mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ca-central-1:111122223333:secret:acse/tenant-01/outbox/promoter/private-key-AbCdEf"
    }
  }
}

mock_provider "github" {
  mock_data "github_repository_file" {
    defaults = {
      content = ""
    }
  }
  mock_data "github_rest_api" {
    defaults = {
      code   = 200
      status = "200 OK"
      # ACSE Read's installation for every case's tenant (github.read_app_id), selection all: no GA-4 warning.
      body = "{\"total_count\":4,\"installations\":[{\"app_id\":1183420,\"repository_selection\":\"all\"},{\"app_id\":3100001,\"repository_selection\":\"all\"},{\"app_id\":4100001,\"repository_selection\":\"all\"},{\"app_id\":2000001,\"repository_selection\":\"all\"}]}"
    }
  }
  mock_resource "github_organization_ruleset" {
    defaults = {
      ruleset_id = 1
    }
  }
}

run "outbox_and_gate_pull_request_mode" {
  command   = apply
  state_key = "outbox_and_gate_pull_request_mode" # each run starts from its own empty state

  variables {
    tenant_yaml                        = file("vectors/cases/outbox-and-gate/tenant.yaml")
    setup_commit                       = "566a44a3b3bcd2b692af3477a4bd1d05ae1872ac"
    policies_default_branch            = "main"
    outbox_default_branch              = "main"
    setup_default_branch               = "main"
    setup_credential_secret_arn        = "arn:aws:secretsmanager:ca-central-1:111122223333:secret:platform/github/acse-setup-app/private-key-AbCdEf"
    setup_apply_environment_reviewers  = { users = [], teams = [1234567] }
    setup_plan_credential_secret_arn   = "arn:aws:secretsmanager:ca-central-1:111122223333:secret:platform/github/acse-setup-plan-app/private-key-MnOpQr"
    setup_credential_extra_reader_arns = ["arn:aws:iam::111122223333:role/platform-break-glass"]
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "ca-central-1" }
  }
  override_resource {
    target = aws_iam_role.promoter
    values = { arn = "arn:aws:iam::111122223333:role/acse-promoter", id = "acse-promoter" }
  }

  assert {
    condition     = jsonencode(output.secret_names) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.secret_names)
    error_message = "Secret names differ from the vectors."
  }
  assert {
    condition     = jsonencode(output.settings_parameter_names) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.settings_parameter_names)
    error_message = "Settings parameter names differ from the vectors."
  }
  assert {
    condition     = jsonencode(output.settings_index_values) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.settings_index_values)
    error_message = "Published settings indexes differ from the vectors."
  }
  assert {
    condition     = output.evidence_public_key_parameter_name == "/acse/tenant-01/evidence/public-key" && output.parameter_arn_prefix == "arn:aws:ssm:ca-central-1:111122223333:parameter/acse/tenant-01"
    error_message = "Parameter naming differs from the vectors."
  }
  assert {
    condition     = output.branch_ruleset_exclude == "refs/heads/acse/**" && output.boundary == "acse"
    error_message = "The default boundary must render exactly acse/**."
  }
  assert {
    condition     = output.promoter_trust_subject == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.promoter.trust_subject
    error_message = "The promoter's trusted subject differs from the vectors."
  }
  assert {
    condition     = jsonencode(jsondecode(output.promoter_trust_policy)) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.promoter.trust_policy)
    error_message = "The promoter's trust policy differs from the vectors."
  }
  assert {
    condition     = length(jsondecode(output.promoter_read_policy).Statement) == 2
    error_message = "Without a customer-managed key the promoter has exactly two statements."
  }
  assert {
    condition     = jsonencode(jsondecode(output.promoter_read_policy).Statement[0]) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.promoter.read_policy_statements[0])
    error_message = "The promoter's parameter grant differs from the vectors."
  }
  assert {
    condition     = jsondecode(output.promoter_read_policy).Statement[1].Action == "secretsmanager:GetSecretValue" && jsondecode(output.promoter_read_policy).Statement[1].Resource == aws_secretsmanager_secret.namespace["outbox/promoter/private-key"].arn
    error_message = "The promoter may read exactly its own key."
  }
  assert {
    condition     = aws_iam_role.promoter[0].name == "acse-promoter" && aws_iam_role.promoter[0].path == "/"
    error_message = "The role's name and path come from cloud.workflow_role."
  }
  assert {
    condition     = output.generated_files["gate"].content == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.generated_files.gate.content
    error_message = ".github/acse-gate.json differs from the vectors."
  }
  assert {
    condition     = output.generated_files["promoter"].content == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.generated_files.promoter.content
    error_message = ".github/acse-promote.json differs from the vectors."
  }
  assert {
    condition     = length(github_repository_pull_request.generated) == 2 && length(github_repository_file.direct) == 0
    error_message = "With both files missing from the default branches, pull_request mode opens two pull requests and commits nothing directly."
  }
  assert {
    condition     = github_branch.generated["gate"].branch == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.generated_files.gate.pull_request_branch
    error_message = "The pull request branch name differs from the vectors."
  }
  assert {
    condition     = github_branch.generated["promoter"].branch == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.generated_files.promoter.pull_request_branch
    error_message = "The pull request branch name differs from the vectors."
  }
  assert {
    condition     = github_organization_ruleset.branches.name == "acse-change-only-on-acse-branches" && github_organization_ruleset.branches.target == "branch" && github_organization_ruleset.branches.enforcement == "evaluate"
    error_message = "The branch ruleset keeps its fixed name (N-17), targets branches and ships in evaluate."
  }
  assert {
    condition     = jsonencode(github_organization_ruleset.branches.conditions[0].ref_name[0].include) == jsonencode(["~ALL"]) && jsonencode(github_organization_ruleset.branches.conditions[0].ref_name[0].exclude) == jsonencode(["refs/heads/acse/**"])
    error_message = "The branch ruleset covers every branch except exactly refs/heads/<boundary>/** (B.5-4)."
  }
  assert {
    condition = alltrue([
      github_organization_ruleset.branches.rules[0].creation,
      github_organization_ruleset.branches.rules[0].update,
      github_organization_ruleset.branches.rules[0].deletion,
      github_organization_ruleset.branches.rules[0].non_fast_forward,
    ])
    error_message = "The branch ruleset restricts creation, update and deletion and blocks force pushes."
  }
  assert {
    condition     = github_organization_ruleset.tags.name == "acse-change-no-tags" && github_organization_ruleset.tags.target == "tag" && alltrue([github_organization_ruleset.tags.rules[0].creation, github_organization_ruleset.tags.rules[0].update, github_organization_ruleset.tags.rules[0].deletion])
    error_message = "The tag ruleset is acse-change-no-tags and restricts creating, updating and deleting tags."
  }
  assert {
    condition     = !contains([for a in github_organization_ruleset.branches.bypass_actors : a.actor_id if a.actor_type == "Integration"], 1183421)
    error_message = "ACSE Change is never on the bypass list."
  }
  assert {
    condition     = jsonencode(sort([for a in github_organization_ruleset.branches.bypass_actors : tostring(a.actor_id) if a.actor_type == "RepositoryRole"])) == jsonencode(["2", "4", "5"])
    error_message = "Repository roles Write, Maintain and Admin bypass."
  }
  assert {
    condition     = github_organization_ruleset.boundary_no_force_push.name == "acse-change-no-force-push" && github_organization_ruleset.boundary_no_force_push.target == "branch"
    error_message = "The boundary's force-push ruleset is acse-change-no-force-push, on branches (DEC-12)."
  }
  assert {
    condition     = jsonencode(github_organization_ruleset.boundary_no_force_push.conditions[0].ref_name[0].include) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.force_push_ruleset_include) && jsonencode(github_organization_ruleset.boundary_no_force_push.conditions[0].ref_name[0].exclude) == jsonencode([])
    error_message = "The force-push ruleset covers exactly refs/heads/acse/** and excludes nothing inside it (LR-6 force_push_blocked)."
  }
  assert {
    condition = (
      github_organization_ruleset.boundary_no_force_push.rules[0].non_fast_forward == true
      && !coalesce(github_organization_ruleset.boundary_no_force_push.rules[0].deletion, false)
      && !coalesce(github_organization_ruleset.boundary_no_force_push.rules[0].creation, false)
      && !coalesce(github_organization_ruleset.boundary_no_force_push.rules[0].update, false)
    )
    error_message = "The force-push ruleset holds non_fast_forward only: deletion stays allowed for the deep test."
  }
  assert {
    condition     = !contains([for a in github_organization_ruleset.boundary_no_force_push.bypass_actors : a.actor_id if a.actor_type == "Integration"], 1183421)
    error_message = "ACSE Change is not on the force-push ruleset's bypass list."
  }
  assert {
    condition     = length(aws_ssm_parameter.settings) == 9 && length(aws_ssm_parameter.settings_part) == 0 && alltrue([for p in aws_ssm_parameter.settings : p.type == "String" && p.tier == "Advanced"])
    error_message = "Nine Advanced String indexes, every section inline, no parts (DEC-6)."
  }
  assert {
    condition     = jsonencode(output.settings_payloads) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.settings_payloads)
    error_message = "Settings payloads differ from the vectors."
  }
  assert {
    condition     = jsondecode(output.settings_index_values["outbox"]).parts == 0 && jsondecode(output.settings_index_values["naming"]).parts == 0
    error_message = "The promoter's two sections are always inline."
  }
  assert {
    condition     = jsonencode(jsondecode(output.setup_roles.apply_trust_policy)) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.setup_roles.apply_trust_policy)
    error_message = "The setup apply role's trust differs from the vectors (environment + job_workflow_ref on the default branch)."
  }
  assert {
    condition     = jsonencode(jsondecode(output.setup_roles.check_trust_policy)) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.setup_roles.check_trust_policy)
    error_message = "The PR-check role's trust differs from the vectors (pull_request only)."
  }
  assert {
    condition     = jsonencode(jsondecode(output.setup_roles.credential_policy)) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.setup_roles.credential_policy)
    error_message = "Only the setup apply role (and the listed break-glass role) may read the setup credential."
  }
  assert {
    condition     = jsonencode(jsondecode(output.setup_roles.plan_trust_policy)) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.setup_roles.plan_trust_policy)
    error_message = "The post-merge plan role trusts only the default branch's acse-setup-apply.yml outside any environment."
  }
  assert {
    condition     = jsonencode(jsondecode(output.setup_roles.plan_secret_policy)) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.setup_roles.plan_secret_policy) && aws_secretsmanager_secret_policy.setup_plan_credential[0].secret_arn == "arn:aws:secretsmanager:ca-central-1:111122223333:secret:platform/github/acse-setup-plan-app/private-key-MnOpQr"
    error_message = "Only the post-merge plan role may read the read-only App's key."
  }
  assert {
    condition     = !contains(jsondecode(output.setup_roles.credential_policy).Statement[0].Condition.StringNotEquals["aws:PrincipalArn"], output.setup_roles.plan_role_arn) && length(distinct([output.setup_roles.apply_role_arn, output.setup_roles.plan_role_arn, output.setup_roles.check_role_arn, output.promoter_role_arn])) == 4
    error_message = "The plan role cannot read the setup App's key; apply, plan, check and promoter are four distinct roles."
  }
  assert {
    condition     = !contains(jsondecode(output.setup_roles.credential_policy).Statement[0].Condition.StringNotEquals["aws:PrincipalArn"], output.setup_roles.check_role_arn) && output.setup_roles.check_role_arn != output.setup_roles.apply_role_arn && output.setup_roles.apply_role_arn != output.promoter_role_arn
    error_message = "The PR-check role cannot read the setup credential; the setup roles and the promoter's are distinct."
  }
  assert {
    condition = (
      github_repository_environment.setup_apply[0].environment == "acse-setup-apply"
      && github_repository_environment.setup_apply[0].can_admins_bypass == false
      && github_repository_environment.setup_apply[0].prevent_self_review == true
      && github_repository_environment.setup_apply[0].deployment_branch_policy[0].custom_branch_policies == true
      && github_repository_environment.setup_apply[0].deployment_branch_policy[0].protected_branches == false
      && github_repository_environment_deployment_policy.setup_apply_default_branch[0].branch_pattern == "main"
      && jsonencode(github_repository_environment.setup_apply[0].reviewers[0].teams) == jsonencode([1234567])
    )
    error_message = "SC-1: the apply environment deploys from the default branch only, has no administrator bypass, prevents self-review and requires the given reviewers."
  }
  assert {
    condition     = length(github_actions_repository_oidc_subject_claim_customization_template.setup) == 1 && jsonencode(github_actions_repository_oidc_subject_claim_customization_template.setup[0].include_claim_keys) == jsonencode(["repo", "context", "job_workflow_ref"]) && aws_secretsmanager_secret_policy.setup_credential[0].secret_arn == "arn:aws:secretsmanager:ca-central-1:111122223333:secret:platform/github/acse-setup-app/private-key-AbCdEf"
    error_message = "The setup repository's subject template is set and the setup credential's policy is attached."
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && output.oidc_provider_arn == "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
    error_message = "By default the existing OIDC provider is used, by its derived ARN."
  }
}

run "matching_default_branch_writes_nothing" {
  command   = apply
  state_key = "matching_default_branch_writes_nothing" # each run starts from its own empty state

  variables {
    tenant_yaml             = file("vectors/cases/outbox-prefixed-boundary/tenant.yaml")
    setup_commit            = "89abcdef0123456789abcdef0123456789abcdef"
    policies_default_branch = "main"
    outbox_default_branch   = "trunk"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "444455556666" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "eu-west-1" }
  }
  override_resource {
    target = aws_iam_role.promoter
    values = { arn = "arn:aws:iam::444455556666:role/acse/acse-promoter-globex", id = "acse-promoter-globex" }
  }
  # The default branch already carries the same file, generated at an older setup commit: generated_from is not
  # compared, so nothing is written.
  override_data {
    target = data.github_repository_file.current
    values = {
      content = <<-EOT
        {
          "promoter_config_format_version": "1.0",
          "tenant": "globex-eu",
          "cloud": {
            "provider": "aws",
            "region": "eu-west-1",
            "workflow_role": "arn:aws:iam::444455556666:role/acse/acse-promoter-globex",
            "namespace": "acse/globex-eu"
          },
          "generated_from": {
            "repository": "globex/platform-acse-setup",
            "commit": "ffffffffffffffffffffffffffffffffffffffff",
            "tenant_yaml_sha256": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
          }
        }
      EOT
    }
  }

  assert {
    condition     = length(github_repository_pull_request.generated) == 0 && length(github_branch.generated) == 0 && length(github_repository_file.on_branch) == 0
    error_message = "A default branch that already matches (generated_from excluded) gets no branch and no pull request."
  }
  assert {
    condition     = jsonencode(keys(output.generated_files)) == jsonencode(["promoter"])
    error_message = "A gate list without gate.audience generates no .github/acse-gate.json."
  }
}

run "outbox_prefixed_boundary_kms_and_job_workflow_ref" {
  command   = apply
  state_key = "outbox_prefixed_boundary_kms_and_job_workflow_ref" # each run starts from its own empty state

  variables {
    tenant_yaml                                   = file("vectors/cases/outbox-prefixed-boundary/tenant.yaml")
    setup_commit                                  = "89abcdef0123456789abcdef0123456789abcdef"
    policies_default_branch                       = "main"
    outbox_default_branch                         = "trunk"
    outbox_oidc_subject_includes_job_workflow_ref = true
    kms_key_arn                                   = "arn:aws:kms:eu-west-1:444455556666:key/0f0e0d0c-0b0a-0908-0706-050403020100"
    ruleset_enforcement                           = "active"
    ruleset_bypass_integration_ids                = [29110]
    setup_credential_secret_arn                   = "arn:aws:secretsmanager:eu-west-1:444455556666:secret:globex/acse-setup-app-key-MnOpQr"
    setup_plan_credential_secret_arn              = "arn:aws:secretsmanager:eu-west-1:444455556666:secret:globex/acse-setup-plan-app-key-StUvWx"
    setup_default_branch                          = "trunk"
    setup_apply_environment_reviewers             = { users = [7000001], teams = [] }
    setup_oidc_subject_repo                       = "globex@9000001/platform-acse-setup@9000002"
    outbox_oidc_subject_repo                      = "globex@9000001/platform-acse-outbox@9000003"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "444455556666" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "eu-west-1" }
  }
  override_resource {
    target = aws_iam_role.promoter
    values = { arn = "arn:aws:iam::444455556666:role/acse/acse-promoter-globex", id = "acse-promoter-globex" }
  }

  assert {
    condition     = output.boundary == "corp-acse-prod" && output.branch_ruleset_exclude == "refs/heads/corp-acse-prod/**"
    error_message = "The boundary is {prefix}acse{suffix}."
  }
  assert {
    condition     = jsonencode(output.settings_index_values) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.settings_index_values)
    error_message = "Published settings differ from the vectors (including the \\u0026 escape)."
  }
  assert {
    condition     = jsonencode(output.secret_names) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.secret_names)
    error_message = "Secret names differ from the vectors."
  }
  assert {
    condition     = output.promoter_trust_subject == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.promoter.trust_subject
    error_message = "With subject customisation the trust names job_workflow_ref on the default branch."
  }
  assert {
    condition     = length(github_actions_repository_oidc_subject_claim_customization_template.outbox) == 1 && jsonencode(github_actions_repository_oidc_subject_claim_customization_template.outbox[0].include_claim_keys) == jsonencode(["repo", "context", "job_workflow_ref"])
    error_message = "The outbox's subject template is set."
  }
  assert {
    condition     = jsonencode(jsondecode(output.promoter_read_policy).Statement[2]) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.promoter.read_policy_statements[2])
    error_message = "kms:Decrypt only through Secrets Manager, only on the customer's key."
  }
  assert {
    condition     = aws_iam_role.promoter[0].name == "acse-promoter-globex" && aws_iam_role.promoter[0].path == "/acse/"
    error_message = "The role's path comes from cloud.workflow_role."
  }
  assert {
    condition     = aws_secretsmanager_secret.namespace["github/read/private-key"].kms_key_id == "arn:aws:kms:eu-west-1:444455556666:key/0f0e0d0c-0b0a-0908-0706-050403020100"
    error_message = "Secrets use the customer-managed key."
  }
  assert {
    condition     = github_organization_ruleset.boundary_no_force_push.name == "acse-change-no-force-push" && github_organization_ruleset.boundary_no_force_push.target == "branch"
    error_message = "The boundary's force-push ruleset is acse-change-no-force-push, on branches (DEC-12)."
  }
  assert {
    condition     = jsonencode(github_organization_ruleset.boundary_no_force_push.conditions[0].ref_name[0].include) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.force_push_ruleset_include) && jsonencode(github_organization_ruleset.boundary_no_force_push.conditions[0].ref_name[0].exclude) == jsonencode([])
    error_message = "The force-push ruleset covers exactly refs/heads/corp-acse-prod/** and excludes nothing inside it (LR-6 force_push_blocked)."
  }
  assert {
    condition = (
      github_organization_ruleset.boundary_no_force_push.rules[0].non_fast_forward == true
      && !coalesce(github_organization_ruleset.boundary_no_force_push.rules[0].deletion, false)
      && !coalesce(github_organization_ruleset.boundary_no_force_push.rules[0].creation, false)
      && !coalesce(github_organization_ruleset.boundary_no_force_push.rules[0].update, false)
    )
    error_message = "The force-push ruleset holds non_fast_forward only: deletion stays allowed for the deep test."
  }
  assert {
    condition     = !contains([for a in github_organization_ruleset.boundary_no_force_push.bypass_actors : a.actor_id if a.actor_type == "Integration"], 3100002)
    error_message = "ACSE Change is not on the force-push ruleset's bypass list."
  }
  assert {
    condition     = github_organization_ruleset.boundary_no_force_push.enforcement == "active"
    error_message = "force_push_blocked passes only when the ruleset is active; it follows ruleset_enforcement."
  }
  assert {
    condition     = output.setup_roles.apply_subject == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.setup_roles.apply_subject && output.setup_roles.check_subject == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.setup_roles.check_subject && length(github_actions_repository_oidc_subject_claim_customization_template.setup) == 1
    error_message = "Under the immutable subject format both setup roles pin repo:owner@id/name@id, in the custom (context + job_workflow_ref) format (SC-1, DEC-29)."
  }
  assert {
    condition     = output.promoter_trust_subject == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[3].expected.promoter.trust_subject
    error_message = "The promoter role pins the outbox's immutable repo segment."
  }
  assert {
    condition     = github_organization_ruleset.branches.enforcement == "active" && contains([for a in github_organization_ruleset.branches.bypass_actors : a.actor_id if a.actor_type == "Integration"], 29110)
    error_message = "Enforcement and the customer's own bots follow the inputs."
  }
}

run "direct_minimal" {
  command   = apply
  state_key = "direct_minimal" # each run starts from its own empty state

  variables {
    tenant_yaml             = file("vectors/cases/direct-minimal/tenant.yaml")
    setup_commit            = "0123456789abcdef0123456789abcdef01234567"
    policies_default_branch = "main"
    generated_files_mode    = "direct"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  assert {
    condition     = jsonencode(output.secret_names) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[0].expected.secret_names)
    error_message = "A Direct tenant has no promoter key."
  }
  assert {
    condition     = jsonencode(output.settings_index_values) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[0].expected.settings_index_values) && jsondecode(output.settings_index_values["naming"]).inline == {} && output.settings_payloads["naming"] == "{}"
    error_message = "settings/naming is published as {} when tenant.yaml has no naming section."
  }
  assert {
    condition     = output.promoter_role_arn == null && length(aws_iam_role.promoter) == 0 && output.promoter_trust_policy == null
    error_message = "A Direct tenant gets no promoter role."
  }
  assert {
    condition     = length(output.generated_files) == 0 && length(github_repository_file.direct) == 0
    error_message = "No outbox and no gate audience: nothing is generated."
  }
}

run "direct_mode_commits_to_the_default_branch" {
  command   = apply
  state_key = "direct_mode_commits_to_the_default_branch" # each run starts from its own empty state

  variables {
    tenant_yaml             = file("vectors/cases/outbox-and-gate/tenant.yaml")
    setup_commit            = "566a44a3b3bcd2b692af3477a4bd1d05ae1872ac"
    policies_default_branch = "main"
    outbox_default_branch   = "main"
    generated_files_mode    = "direct"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "ca-central-1" }
  }
  override_resource {
    target = aws_iam_role.promoter
    values = { arn = "arn:aws:iam::111122223333:role/acse-promoter", id = "acse-promoter" }
  }

  assert {
    condition     = length(github_repository_file.direct) == 2 && length(github_repository_pull_request.generated) == 0
    error_message = "direct mode commits both files and opens no pull request."
  }
  assert {
    condition     = github_repository_file.direct["gate"].repository == "acse-policies" && github_repository_file.direct["gate"].file == ".github/acse-gate.json" && github_repository_file.direct["promoter"].file == ".github/acse-promote.json"
    error_message = "Each file goes to its own repository and path."
  }
  assert {
    condition     = github_repository_file.direct["gate"].content == jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[2].expected.generated_files.gate.content
    error_message = "The committed file is the vector's bytes."
  }
}

run "large_sections_split_into_parts" {
  command   = apply
  state_key = "large_sections_split_into_parts" # each run starts from its own empty state

  variables {
    tenant_yaml             = file("vectors/cases/large-split/tenant.yaml")
    setup_commit            = "fedcba9876543210fedcba9876543210fedcba98"
    policies_default_branch = "main"
    generated_files_mode    = "direct"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "777788889999" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "ca-central-1" }
  }

  assert {
    condition     = jsonencode(output.settings_index_values) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[1].expected.settings_index_values)
    error_message = "Settings indexes differ from the vectors."
  }
  assert {
    condition     = jsonencode(output.settings_part_values) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[1].expected.settings_part_values)
    error_message = "Settings parts differ from the vectors."
  }
  assert {
    condition     = jsonencode(output.settings_part_names) == jsonencode(jsondecode(file("vectors/acse-tenant-vectors-1.0.json")).cases[1].expected.settings_part_names)
    error_message = "Settings part names differ from the vectors (/acse/<tenant>/settings/<section>/<i>)."
  }
  assert {
    condition     = jsondecode(output.settings_index_values["gate"]).parts > 0 && !can(jsondecode(output.settings_index_values["gate"]).inline) && jsondecode(output.settings_index_values["github"]).parts == 0
    error_message = "A large section is split and carries no inline value; a small one stays inline."
  }
  assert {
    condition     = join("", [for i in range(jsondecode(output.settings_index_values["gate"]).parts) : output.settings_part_values["gate/${i}"]]) == output.settings_payloads["gate"] && "sha256:${sha256(output.settings_payloads["gate"])}" == jsondecode(output.settings_index_values["gate"]).sha256
    error_message = "The parts reassemble to the payload whose sha256 the index carries."
  }
  assert {
    condition     = alltrue([for p in aws_ssm_parameter.settings_part : p.tier == "Advanced"]) && length(aws_ssm_parameter.settings_part) == length(output.settings_part_values)
    error_message = "Every part is an Advanced parameter."
  }
  assert {
    condition     = output.setup_roles == null && length(aws_iam_role.setup_apply) == 0
    error_message = "Without setup_credential_secret_arn no setup role is created."
  }
}

run "refuses_a_setup_credential_inside_the_namespace" {
  command   = plan
  state_key = "refuses_a_setup_credential_inside_the_namespace" # each run starts from its own empty state

  variables {
    tenant_yaml                       = file("vectors/cases/direct-minimal/tenant.yaml")
    setup_commit                      = "0123456789abcdef0123456789abcdef01234567"
    setup_default_branch              = "main"
    setup_credential_secret_arn       = "arn:aws:secretsmanager:us-east-1:111122223333:secret:acse/acme/setup/github-app-AbCdEf"
    setup_plan_credential_secret_arn  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:platform/setup-plan-app-AbCdEf"
    setup_apply_environment_reviewers = { users = [1], teams = [] }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_one_role_for_apply_and_check" {
  command   = plan
  state_key = "refuses_one_role_for_apply_and_check" # each run starts from its own empty state

  variables {
    tenant_yaml                       = file("vectors/cases/direct-minimal/tenant.yaml")
    setup_commit                      = "0123456789abcdef0123456789abcdef01234567"
    setup_default_branch              = "main"
    setup_credential_secret_arn       = "arn:aws:secretsmanager:us-east-1:111122223333:secret:platform/setup-app-AbCdEf"
    setup_plan_credential_secret_arn  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:platform/setup-plan-app-AbCdEf"
    setup_check_role_name             = "acse-setup-apply"
    setup_apply_environment_reviewers = { users = [1], teams = [] }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_an_apply_environment_without_reviewers" {
  command   = plan
  state_key = "refuses_an_apply_environment_without_reviewers" # each run starts from its own empty state

  variables {
    tenant_yaml                      = file("vectors/cases/direct-minimal/tenant.yaml")
    setup_commit                     = "0123456789abcdef0123456789abcdef01234567"
    setup_default_branch             = "main"
    setup_credential_secret_arn      = "arn:aws:secretsmanager:us-east-1:111122223333:secret:platform/setup-app-AbCdEf"
    setup_plan_credential_secret_arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:platform/setup-plan-app-AbCdEf"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_setup_without_the_read_only_app_key" {
  command   = plan
  state_key = "refuses_setup_without_the_read_only_app_key" # each run starts from its own empty state

  variables {
    tenant_yaml                       = file("vectors/cases/direct-minimal/tenant.yaml")
    setup_commit                      = "0123456789abcdef0123456789abcdef01234567"
    setup_default_branch              = "main"
    setup_credential_secret_arn       = "arn:aws:secretsmanager:us-east-1:111122223333:secret:platform/setup-app-AbCdEf"
    setup_apply_environment_reviewers = { users = [1], teams = [] }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_an_outbox_without_its_default_branch" {
  command   = plan
  state_key = "refuses_an_outbox_without_its_default_branch" # each run starts from its own empty state

  variables {
    tenant_yaml             = file("vectors/cases/outbox-and-gate/tenant.yaml")
    setup_commit            = "566a44a3b3bcd2b692af3477a4bd1d05ae1872ac"
    policies_default_branch = "main"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "ca-central-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_a_namespace_that_is_not_the_tenants" {
  command   = plan
  state_key = "refuses_a_namespace_that_is_not_the_tenants" # each run starts from its own empty state

  variables {
    tenant_yaml  = replace(file("vectors/cases/direct-minimal/tenant.yaml"), "namespace: acse/acme", "namespace: acse/other")
    setup_commit = "0123456789abcdef0123456789abcdef01234567"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_acse_change_on_the_bypass_list" {
  command   = plan
  state_key = "refuses_acse_change_on_the_bypass_list" # each run starts from its own empty state

  variables {
    tenant_yaml                    = file("vectors/cases/direct-minimal/tenant.yaml")
    setup_commit                   = "0123456789abcdef0123456789abcdef01234567"
    ruleset_bypass_integration_ids = [2000002]
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_another_account" {
  command   = plan
  state_key = "refuses_another_account" # each run starts from its own empty state

  variables {
    tenant_yaml  = file("vectors/cases/direct-minimal/tenant.yaml")
    setup_commit = "0123456789abcdef0123456789abcdef01234567"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "999999999999" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}

run "refuses_ruleset_enforcement" {
  command   = plan
  state_key = "refuses_ruleset_enforcement" # each run starts from its own empty state

  variables {
    tenant_yaml  = "${file("vectors/cases/direct-minimal/tenant.yaml")}gate:\n  enforcement: ruleset\n  registered_repositories:\n    - repo: acme-corp/acse-policies\n      workflow: .github/workflows/acse-gate.yml\n"
    setup_commit = "0123456789abcdef0123456789abcdef01234567"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  expect_failures = [terraform_data.tenant_config]
}
