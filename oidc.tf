# The GitHub OIDC trust (T-6) and the promoter's narrow role (spec 02e Amendment 2 item 2; ledger 02e Q-2, section
# 10.3). cloud.workflow_role is the promoter's role only: trusted for acse-promote.yml on the outbox repository's
# default branch, reading exactly settings/outbox, settings/naming, evidence/public-key and
# outbox/promoter/private-key. This is the one namespace-scoped grant; every other reader has its own role.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

# Recommended, off by default (ledger 02e section 10.3 and 10.10): bind the outbox's subject to the workflow file.
resource "github_actions_repository_oidc_subject_claim_customization_template" "outbox" {
  count = local.has_outbox && var.outbox_oidc_subject_includes_job_workflow_ref ? 1 : 0

  repository         = local.outbox_name
  use_default        = false
  include_claim_keys = ["repo", "context", "job_workflow_ref"]
}

locals {
  promoter_trust_policy = local.has_outbox ? jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AcsePromoteOnTheOutboxDefaultBranchOnly"
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = local.promoter_subject
        }
      }
    }]
  }) : null

  promoter_read_policy = local.has_outbox ? jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadThePromotersThreeParameters"
          Effect   = "Allow"
          Action   = "ssm:GetParameters"
          Resource = local.promoter_parameter_arns
        },
        {
          Sid      = "ReadThePromotersAppKey"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = try(aws_secretsmanager_secret.namespace["outbox/promoter/private-key"].arn, null)
        },
      ],
      var.kms_key_arn == null ? [] : [{
        Sid       = "DecryptThePromotersAppKeyThroughSecretsManagerOnly"
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = var.kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" } }
      }],
    )
  }) : null
}

resource "aws_iam_role" "promoter" {
  count = local.manage_role ? 1 : 0

  name                 = local.promoter_role_name
  path                 = local.promoter_role_path
  description          = "ACSE promoter (${local.tenant}): acse-promote.yml on ${local.outbox_full}@${local.outbox_default_branch} only. Reads four namespace entries, nothing else."
  assume_role_policy   = local.promoter_trust_policy
  max_session_duration = 3600
  tags                 = merge(var.tags, { "acse:tenant" = local.tenant })

  depends_on = [terraform_data.tenant_config]

  lifecycle {
    postcondition {
      condition     = self.arn == local.promoter_role_arn
      error_message = "The created role's ARN differs from cloud.workflow_role."
    }
  }
}

resource "aws_iam_role_policy" "promoter_reads" {
  count = local.manage_role ? 1 : 0

  name   = "acse-promoter-store-reads"
  role   = aws_iam_role.promoter[0].id
  policy = local.promoter_read_policy
}
