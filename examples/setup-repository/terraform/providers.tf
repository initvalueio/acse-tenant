# Credentials, all by identity (spec 02e T-4, T-6; DEC-20; SC-1, SC-5): no GitHub secret, no GitHub variable.
#
# AWS: the workflow's OIDC token, exchanged for the phase's role. The module creates the three roles:
#   check -> acse-setup-check: pull requests only; broad read; no GitHub credential (SC-5).
#   plan  -> acse-setup-plan:  the default branch's post-merge plan job; broad read; reads only the read-only App's key.
#   apply -> acse-setup-apply: the default branch's apply job in the acse-setup-apply environment only; the only role
#            that can read the setup App's key.
# The very first apply (bootstrap, T-8) runs before those roles and the setup repository's OIDC subject template
# exist: run it once as an administrator with use_web_identity = false and your own credentials, with that
# administrator role in bootstrap_admin_role_arns.
#
# GitHub, by phase:
#   check -> NO GitHub credential (SC-5): the provider is anonymous and the workflow plans the cloud side only;
#   plan  -> your read-only App (administration, contents, pull requests, metadata read; no write);
#   apply -> your setup App (organization administration write).
# Each key sits in a Secrets Manager secret you name OUTSIDE acse/<tenant>/, read through an ephemeral resource. Terraform >= 1.10 keeps an
# ephemeral value out of state and out of the plan file; below that floor, or on an OpenTofu release whose provider
# blocks do not accept ephemeral values, the key would land in the plan file.

locals {
  account = tostring(local.tenant.cloud.account)
  phase_role_arn = {
    check = "arn:aws:iam::${local.account}:role/${var.setup_check_role_name}"
    plan  = "arn:aws:iam::${local.account}:role/${var.setup_plan_role_name}"
    apply = "arn:aws:iam::${local.account}:role/${var.setup_apply_role_name}"
  }
  # The App each phase signs in with; check has none.
  phase_app = {
    check = null
    plan  = var.plan_app
    apply = var.setup_app
  }
  github_app = local.phase_app[var.acse_setup_phase]
}

provider "aws" {
  region              = local.tenant.cloud.region
  allowed_account_ids = [local.account]

  dynamic "assume_role_with_web_identity" {
    for_each = var.use_web_identity ? [1] : []
    content {
      role_arn     = local.phase_role_arn[var.acse_setup_phase]
      session_name = "acse-setup-${var.acse_setup_phase}"
      # web_identity_token_file: from AWS_WEB_IDENTITY_TOKEN_FILE (set by acse-setup-apply.yml).
    }
  }
}

ephemeral "aws_secretsmanager_secret_version" "github_app_key" {
  count     = local.github_app == null ? 0 : 1
  secret_id = local.github_app.private_key_secret_arn
}

provider "github" {
  owner = split("/", local.tenant.repositories.setup)[0]

  dynamic "app_auth" {
    for_each = local.github_app == null ? [] : [1]
    content {
      id              = local.github_app.id
      installation_id = local.github_app.installation_id
      pem_file        = ephemeral.aws_secretsmanager_secret_version.github_app_key[0].secret_string
    }
  }
}
