# The setup apply's own identities (DEC-20; SC-1 and SC-5, the Architecture Owner 2026-11-07).
#
# The setup credential is the customer's own GitHub App (organization administration write). Its key sits in a
# Secrets Manager secret the customer names, outside acse/<tenant>/, so that no ACSE identity can ever reach it: the
# runtime's read grant covers the namespace only. This module never reads it; the customer's root reads it through an
# ephemeral resource in the apply phase only, so it never reaches state or the plan file.
#
# Two roles, distinct from each other, from cloud.workflow_role (the promoter's) and from the runtime's:
#   apply  -- the only role that can read the secret. Trusted only for the sub
#             repo:<setup>:environment:acse-setup-apply:job_workflow_ref:<setup>/.github/workflows/acse-setup-apply.yml@refs/heads/<default>
#             (SC-1: AWS trust conditions can match only sub and aud, so the workflow file and branch must be in sub).
#   plan   -- the post-merge plan (third round, "Read-only post-merge plan job"): the default branch's plan job, with
#             no approval gate, sub repo:<s>:ref:refs/heads/<default>:job_workflow_ref:<workflow>@refs/heads/<default>.
#             It reads only the read-only App's key (its own customer-named secret, whose resource policy allows only
#             this role) and posts the full GitHub and cloud plan before anyone approves the apply.
#   check  -- the pull request's plan of the cloud side (SC-5). No GitHub credential is reachable from it, and it
#             cannot read either secret.
#
# The setup repository's OIDC subject template is always repo + context + job_workflow_ref (SC-1; no off-switch).
# "context" and not "environment": GitHub documents that including the environment claim key makes an environment
# required, which the pull request's job does not have; "context" renders environment:<name> for a job in an
# environment and pull_request for a pull request job (docs/decisions.md DEC-28). The template applies to every
# workflow in the setup repository, so the check role's trust is written against the same custom format.
#
# Ordering (bootstrap, T-8): the first apply is the customer's one-time bootstrap, run with their own administrator
# credentials, not with either role. A role whose trust names the custom sub can exist before the template does;
# it is only assumed later, by the workflow, after the bootstrap has created both. So no depends_on links them, which
# also keeps the GitHub-side resource out of the pull request's cloud-only plan (-target, SC-5).

locals {
  setup_enabled  = var.setup_credential_secret_arn != null
  setup_full     = tostring(local.repositories.setup)
  setup_name     = split("/", local.repositories.setup)[1]
  setup_workflow = "${local.setup_full}/.github/workflows/acse-setup-apply.yml"
  setup_default  = coalesce(var.setup_default_branch, "UNSET-setup_default_branch") # refused in validation.tf when unset

  # The repo segment of sub: owner/name, or owner@id/name@id under GitHub's immutable subject format (repositories
  # created after 2026-07-15 use it by default). DEC-29.
  setup_sub_repo = coalesce(var.setup_oidc_subject_repo, local.setup_full)

  setup_apply_arn = "arn:aws:iam::${local.account}:role/${var.setup_apply_role_name}"
  setup_check_arn = "arn:aws:iam::${local.account}:role/${var.setup_check_role_name}"
  setup_plan_arn  = "arn:aws:iam::${local.account}:role/${var.setup_plan_role_name}"

  setup_apply_subject = !local.setup_enabled ? null : "repo:${local.setup_sub_repo}:environment:${var.setup_apply_environment}:job_workflow_ref:${local.setup_workflow}@refs/heads/${local.setup_default}"
  # A push job with no environment: context is ref:refs/heads/<branch> (GitHub's default-format branch part). AWS can
  # match only sub and aud, so "push only" is the template's job condition, not the trust's (DEC-30).
  setup_plan_subject  = !local.setup_enabled ? null : "repo:${local.setup_sub_repo}:ref:refs/heads/${local.setup_default}:job_workflow_ref:${local.setup_workflow}@refs/heads/${local.setup_default}"
  setup_check_subject = !local.setup_enabled ? null : "repo:${local.setup_sub_repo}:pull_request:job_workflow_ref:${local.setup_workflow}@refs/pull/*/merge"

  setup_apply_trust_policy = !local.setup_enabled ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AcseSetupApplyJobOnly"
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = local.setup_apply_subject
        }
      }
    }]
  })

  setup_plan_trust_policy = !local.setup_enabled ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AcseSetupPostMergePlanJobOnly"
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = local.setup_plan_subject
        }
      }
    }]
  })

  setup_plan_credential_policy = !local.setup_enabled ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "OnlyThePostMergePlanRoleReadsThisKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "secretsmanager:GetSecretValue"
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:PrincipalArn" = [local.setup_plan_arn] } }
      },
      {
        Sid       = "ThePostMergePlanRoleReadsThisKey"
        Effect    = "Allow"
        Principal = { AWS = local.setup_plan_arn }
        Action    = "secretsmanager:GetSecretValue"
        Resource  = "*"
      },
    ]
  })

  # StringLike only for the pull request number; every other character is literal, so any other shape (a job in an
  # environment, a push, another workflow file, the default subject format) is refused: it fails closed.
  setup_check_trust_policy = !local.setup_enabled ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AcseSetupPullRequestCheckOnly"
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com" }
        StringLike   = { "${local.oidc_host}:sub" = local.setup_check_subject }
      }
    }]
  })

  setup_credential_readers = concat([local.setup_apply_arn], var.setup_credential_extra_reader_arns)

  setup_credential_policy = !local.setup_enabled ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "OnlyTheSetupApplyRoleReadsThisKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "secretsmanager:GetSecretValue"
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:PrincipalArn" = local.setup_credential_readers } }
      },
      {
        Sid       = "TheSetupApplyRoleReadsThisKey"
        Effect    = "Allow"
        Principal = { AWS = local.setup_apply_arn }
        Action    = "secretsmanager:GetSecretValue"
        Resource  = "*"
      },
    ]
  })
}

# The apply environment (SC-1): deployable from the default branch only, no administrator bypass, self-review
# prevented, and at least one required reviewer (validation.tf).
resource "github_repository_environment" "setup_apply" {
  count = local.setup_enabled ? 1 : 0

  repository          = local.setup_name
  environment         = var.setup_apply_environment
  prevent_self_review = true
  can_admins_bypass   = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }

  reviewers {
    users = var.setup_apply_environment_reviewers.users
    teams = var.setup_apply_environment_reviewers.teams
  }

  depends_on = [terraform_data.tenant_config]
}

resource "github_repository_environment_deployment_policy" "setup_apply_default_branch" {
  count = local.setup_enabled ? 1 : 0

  repository     = local.setup_name
  environment    = github_repository_environment.setup_apply[0].environment
  branch_pattern = local.setup_default
}

resource "github_actions_repository_oidc_subject_claim_customization_template" "setup" {
  count = local.setup_enabled ? 1 : 0

  repository         = local.setup_name
  use_default        = false
  include_claim_keys = ["repo", "context", "job_workflow_ref"]
}

resource "aws_iam_role" "setup_apply" {
  count = local.setup_enabled ? 1 : 0

  name                 = var.setup_apply_role_name
  description          = "ACSE setup apply (${local.tenant}): acse-setup-apply.yml's apply job on ${local.setup_full}@${local.setup_default}, environment ${var.setup_apply_environment}. The only role that reads the setup credential."
  assume_role_policy   = local.setup_apply_trust_policy
  max_session_duration = 3600
  tags                 = merge(var.tags, { "acse:tenant" = local.tenant, "acse:role" = "setup-apply" })

  depends_on = [terraform_data.tenant_config]
}

resource "aws_iam_role_policy_attachment" "setup_apply" {
  for_each = local.setup_enabled ? toset(var.setup_apply_policy_arns) : toset([])

  role       = aws_iam_role.setup_apply[0].name
  policy_arn = each.value
}

resource "aws_iam_role" "setup_plan" {
  count = local.setup_enabled ? 1 : 0

  name                 = var.setup_plan_role_name
  description          = "ACSE setup post-merge plan (${local.tenant}): acse-setup-apply.yml's plan job on ${local.setup_full}@${local.setup_default}. Reads only the read-only App's key; cannot read the setup credential."
  assume_role_policy   = local.setup_plan_trust_policy
  max_session_duration = 3600
  tags                 = merge(var.tags, { "acse:tenant" = local.tenant, "acse:role" = "setup-plan" })

  depends_on = [terraform_data.tenant_config]
}

resource "aws_iam_role_policy_attachment" "setup_plan" {
  for_each = local.setup_enabled ? toset(var.setup_plan_policy_arns) : toset([])

  role       = aws_iam_role.setup_plan[0].name
  policy_arn = each.value
}

resource "aws_secretsmanager_secret_policy" "setup_plan_credential" {
  count = local.setup_enabled ? 1 : 0

  secret_arn          = var.setup_plan_credential_secret_arn
  policy              = local.setup_plan_credential_policy
  block_public_policy = true

  depends_on = [aws_iam_role.setup_plan]
}

resource "aws_iam_role" "setup_check" {
  count = local.setup_enabled ? 1 : 0

  name                 = var.setup_check_role_name
  description          = "ACSE setup PR check (${local.tenant}): plans the cloud side of pull requests on ${local.setup_full}. Holds no GitHub credential and cannot read the setup credential."
  assume_role_policy   = local.setup_check_trust_policy
  max_session_duration = 3600
  tags                 = merge(var.tags, { "acse:tenant" = local.tenant, "acse:role" = "setup-check" })

  depends_on = [terraform_data.tenant_config]
}

resource "aws_iam_role_policy_attachment" "setup_check" {
  for_each = local.setup_enabled ? toset(var.setup_check_policy_arns) : toset([])

  role       = aws_iam_role.setup_check[0].name
  policy_arn = each.value
}

resource "aws_secretsmanager_secret_policy" "setup_credential" {
  count = local.setup_enabled ? 1 : 0

  secret_arn          = var.setup_credential_secret_arn
  policy              = local.setup_credential_policy
  block_public_policy = true

  depends_on = [aws_iam_role.setup_apply]
}
