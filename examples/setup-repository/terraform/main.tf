# An example terraform/ root for the customer's setup repository, driven by acse-setup-apply.yml. Copy it into
# terraform/ next to config/tenant.yaml and fill terraform.tfvars and the backend files. Everything here is yours:
# ACSE reads none of it.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.6.0, < 7.0.0"
    }
  }

  # Partial S3 backend: acse-setup-apply.yml passes -backend-config=backend.<phase>.hcl (see backend.plan.hcl.example
  # and backend.apply.hcl.example), so the plan and the apply can sign in with different roles. The web identity
  # token comes from AWS_WEB_IDENTITY_TOKEN_FILE, which the workflow sets.
  backend "s3" {}
}

locals {
  tenant = yamldecode(file("${path.module}/../config/tenant.yaml"))
}

# The module call must be named acse_tenant: the pull request's cloud-only plan targets module.acse_tenant.<resource>.
module "acse_tenant" {
  # In your repository: source = "github.com/initvalueio/acse-tenant?ref=v1.0.0"
  source = "../../.."

  tenant_yaml  = file("${path.module}/../config/tenant.yaml")
  setup_commit = var.setup_commit

  # The App this apply uses pushes setup-apply/* branches outside the ACSE boundary, so it bypasses the rulesets like
  # your other bots. ACSE Change must never be listed here.
  ruleset_bypass_integration_ids = concat([var.setup_app.id], var.other_bot_app_ids)
  ruleset_enforcement            = var.ruleset_enforcement

  # DEC-20, SC-1, SC-5: the setup App's key, outside acse/<tenant>/, readable by the apply role only.
  setup_credential_secret_arn        = var.setup_app.private_key_secret_arn
  setup_plan_credential_secret_arn   = var.plan_app.private_key_secret_arn
  setup_plan_role_name               = var.setup_plan_role_name
  setup_default_branch               = var.default_branches.setup
  policies_default_branch            = var.default_branches.policies
  outbox_default_branch              = var.default_branches.outbox
  setup_oidc_subject_repo            = var.oidc_subject_repo.setup
  outbox_oidc_subject_repo           = var.oidc_subject_repo.outbox
  setup_credential_extra_reader_arns = var.bootstrap_admin_role_arns
  setup_apply_role_name              = var.setup_apply_role_name
  setup_check_role_name              = var.setup_check_role_name
  setup_apply_environment_reviewers  = var.apply_environment_reviewers

  # Opt-in reads ACSE's setup never requests (terraform.tfvars.example lists each one and the checks it unlocks).
  optional_permissions = var.optional_permissions
}

output "acse_tenant" {
  description = "What the setup apply built, for the Access page's Verify steps."
  value = {
    namespace         = module.acse_tenant.namespace
    secret_names      = module.acse_tenant.secret_names
    settings          = module.acse_tenant.settings_parameter_names
    promoter_role_arn = module.acse_tenant.promoter_role_arn
    setup_roles       = module.acse_tenant.setup_roles
    rulesets          = module.acse_tenant.ruleset_ids
    pull_requests     = module.acse_tenant.generated_file_pull_requests
  }
}
