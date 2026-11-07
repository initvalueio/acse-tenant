# SaaS mode: publish into InitValue's namespace, write-only (spec 02e Amendment 6 section A; SA-1 to SA-7).
#
# The publish role (saas_publish_role_arn) can never read: no GetParameter, no GetSecretValue, no Describe*. An
# aws_ssm_parameter or aws_secretsmanager_secret_version reads its value back on every refresh, so neither can be
# used. Instead, each write is a provisioner that runs only when Terraform creates the object, that is only on apply,
# and calls scripts/saas-publish.sh, which signs in as the publish role and nothing else. State keeps no value:
#
#   terraform_data.saas_settings[<section>]  triggers_replace = {commit, sha256, parts}. On create it puts parts
#                                            0..n-1, then the index (parts first, index last: Amendment 5 section A.3).
#                                            Every apply carries a new commit, so every apply republishes every section,
#                                            as the self-hosted mode rewrites every index (SC-4).
#   terraform_data.saas_slot[<name>]         one per published parameter: the index of each section, and each part.
#                                            It holds only the parameter's name. Its destroy-time provisioner deletes
#                                            that parameter. So when a section shrinks from 5 parts to 2, slots 2..4
#                                            leave the configuration and their parameters are deleted, and the previous
#                                            count comes from state, as SA-1 asks.
#   terraform_data.saas_app_keys             triggers_replace = saas_app_keys_version. On create it puts a new version
#                                            of github/read/private-key and github/change/private-key (PutSecretValue).
#                                            The keys are ephemeral inputs: they reach the provisioner's environment
#                                            and nothing else.
#
# Ordering. saas_settings depends on every slot and is create_before_destroy. On a shrink Terraform creates the new
# saas_settings (parts, then index), then destroys the old one (which does nothing), and only then destroys the slots
# it depended on, so a stale part is deleted only after the index that no longer names it is in place.
#
# The plan job and the pull request's job never run a provisioner (a plan does not), so they never assume the role
# (Amendment 6 A.6). Turning saas_publish_on_apply off removes saas_settings and keeps the slots: nothing is deleted.

locals {
  saas_script = "${path.module}/scripts/saas-publish.sh"

  # The settings parameters this tenant publishes: each section's index and each part, by key.
  saas_slots = local.saas ? merge(local.settings_names, local.settings_part_names) : {}

  saas_app_key_secret_names = {
    read   = "${local.namespace}/github/read/private-key"
    change = "${local.namespace}/github/change/private-key"
  }

  # What InitValue's pipeline gives the role (SA-1, SA-2): published here so the infra entry can be pinned to it.
  saas_publish_policy = !local.saas ? null : jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "WriteThisTenantsSettingsOnly"
          Effect   = "Allow"
          Action   = ["ssm:PutParameter", "ssm:DeleteParameter"]
          Resource = "${local.parameter_arn_prefix}/settings/*"
        },
        {
          Sid    = "PutThisTenantsAppKeysOnly"
          Effect = "Allow"
          Action = "secretsmanager:PutSecretValue"
          Resource = [
            "arn:aws:secretsmanager:${local.region}:${local.account}:secret:${local.saas_app_key_secret_names.read}-??????",
            "arn:aws:secretsmanager:${local.region}:${local.account}:secret:${local.saas_app_key_secret_names.change}-??????",
          ]
        },
      ],
      var.kms_key_arn == null ? [] : [{
        Sid       = "EncryptTheAppKeysThroughSecretsManagerOnly"
        Effect    = "Allow"
        Action    = "kms:GenerateDataKey"
        Resource  = var.kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" } }
      }],
    )
  })

  # The role's trust, for InitValue's pipeline: the apply job's SC-1 subject, through the runtime account's own GitHub
  # OIDC provider (SA-2 reuses the one the bootstrap created).
  saas_publish_trust_policy = !local.saas || !local.setup_enabled ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AcseSetupApplyJobOnly"
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${local.account}:oidc-provider/${local.oidc_host}" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = local.setup_apply_subject
        }
      }
    }]
  })
}

resource "terraform_data" "saas_slot" {
  for_each = local.saas_slots

  # Everything the destroy-time provisioner needs, since it may refer only to self. No value.
  input = {
    name     = each.value
    region   = local.region
    role_arn = var.saas_publish_role_arn
    script   = local.saas_script
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", self.input.script]
    command     = "delete"
    environment = {
      ACSE_REGION           = self.input.region
      ACSE_PUBLISH_ROLE_ARN = self.input.role_arn
      ACSE_PARAMETER_NAME   = self.input.name
    }
  }

  depends_on = [terraform_data.tenant_config]
}

resource "terraform_data" "saas_settings" {
  for_each = local.saas_publish ? local.settings_index : {}

  triggers_replace = {
    commit = var.setup_commit
    sha256 = local.settings_sha256[each.key]
    parts  = local.settings_parts_count[each.key]
  }

  provisioner "local-exec" {
    interpreter = ["bash", local.saas_script]
    command     = "settings"
    environment = merge(
      {
        ACSE_REGION           = local.region
        ACSE_PUBLISH_ROLE_ARN = var.saas_publish_role_arn
        ACSE_INDEX_NAME       = local.settings_names[each.key]
        ACSE_INDEX_VALUE      = each.value
        ACSE_PART_COUNT       = tostring(local.settings_parts_count[each.key])
      },
      { for i in range(local.settings_parts_count[each.key]) : "ACSE_PART_${i}" => local.settings_parts["${each.key}/${i}"] },
    )
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [terraform_data.tenant_config, terraform_data.saas_slot]
}

resource "terraform_data" "saas_app_keys" {
  count = local.saas_publish && var.saas_app_keys_version != null ? 1 : 0

  triggers_replace = var.saas_app_keys_version

  provisioner "local-exec" {
    interpreter = ["bash", local.saas_script]
    command     = "app-keys"
    environment = {
      ACSE_REGION             = local.region
      ACSE_PUBLISH_ROLE_ARN   = var.saas_publish_role_arn
      ACSE_READ_SECRET_NAME   = local.saas_app_key_secret_names.read
      ACSE_CHANGE_SECRET_NAME = local.saas_app_key_secret_names.change
      ACSE_READ_APP_KEY       = var.saas_read_app_private_key == null ? "" : var.saas_read_app_private_key
      ACSE_CHANGE_APP_KEY     = var.saas_change_app_private_key == null ? "" : var.saas_change_app_private_key
    }
  }

  depends_on = [terraform_data.tenant_config]
}
