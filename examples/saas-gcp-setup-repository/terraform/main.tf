# An example terraform/ root for a SaaS tenant whose setup credential lives in Google Cloud (spec 02e Amendment 6
# section A, SA-5). InitValue hosts the runtime and the namespace acse/<tenant>/ in its AWS runtime account; this root
# never signs in to AWS itself. On apply, the module's publish step assumes the per-tenant publish role InitValue gave
# you (saas_publish_role_arn, from the Access page) and writes settings/* and the App keys, write-only.
#
# The apply job federates twice: to your Google Cloud project for the keys (this file's google provider), and to
# InitValue's publish role (the module's publish step). The plan and check jobs federate only to Google Cloud, and
# never reach the publish role or the setup App's key.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # Required by the module. In this setup it plans no AWS resource and needs no provider block or credentials.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.6.0, < 7.0.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0.0, < 8.0.0"
    }
  }

  # Your state, in your own bucket. Give the backend the same external_account credential through
  # backend.<phase>.hcl, or keep state elsewhere you control.
  backend "gcs" {}
}

locals {
  tenant = yamldecode(file("${path.module}/../config/tenant.yaml"))
}

# The module call must be named acse_tenant: the pull request's cloud-only plan targets module.acse_tenant.<resource>.
module "acse_tenant" {
  # In your repository: source = "github.com/initvalueio/acse-tenant?ref=v1.1.0"
  source = "../../.."

  tenant_yaml  = file("${path.module}/../config/tenant.yaml")
  setup_commit = var.setup_commit

  # SaaS mode: no namespace, OIDC provider or promoter role here; settings/* are published write-only.
  saas_publish_role_arn       = var.saas_publish_role_arn
  saas_publish_on_apply       = var.use_web_identity # the bootstrap apply cannot assume the publish role
  saas_app_keys_version       = var.acse_app_keys.version
  saas_read_app_private_key   = try(ephemeral.google_secret_manager_secret_version.acse_app_key["read"].secret_data, null)
  saas_change_app_private_key = try(ephemeral.google_secret_manager_secret_version.acse_app_key["change"].secret_data, null)

  # SA-5: the setup and plan Apps' keys are in Google Cloud Secret Manager.
  setup_credential_store            = "gcp"
  setup_default_branch              = var.default_branches.setup
  policies_default_branch           = var.default_branches.policies
  setup_oidc_subject_repo           = var.setup_oidc_subject_repo
  setup_apply_environment_reviewers = var.apply_environment_reviewers

  ruleset_bypass_integration_ids = concat([var.setup_app.id], var.other_bot_app_ids)
  ruleset_enforcement            = var.ruleset_enforcement
}

# The pool, the provider and the secret grants that let only the apply job read the setup App's key (and the ACSE
# App keys), and only the plan job read the read-only App's key.
module "gcp_setup_credential" {
  # In your repository: source = "github.com/initvalueio/acse-tenant//modules/gcp-setup-credential?ref=v1.1.0"
  source = "../../../modules/gcp-setup-credential"

  project_id                      = var.gcp_project_id
  setup_repository                = local.tenant.repositories.setup
  setup_oidc_subjects             = module.acse_tenant.setup_oidc_subjects
  setup_credential_secret_id      = var.setup_app.private_key_secret_id
  setup_plan_credential_secret_id = var.plan_app.private_key_secret_id
  app_key_secret_ids              = [var.acse_app_keys.read_secret_id, var.acse_app_keys.change_secret_id]
}

output "acse_tenant" {
  description = "What the setup apply built, for the Access page's Verify steps."
  value = {
    namespace                  = module.acse_tenant.namespace
    saas                       = module.acse_tenant.saas
    setup_oidc_subjects        = module.acse_tenant.setup_oidc_subjects
    workload_identity_provider = module.gcp_setup_credential.workload_identity_provider
    rulesets                   = module.acse_tenant.ruleset_ids
    pull_requests              = module.acse_tenant.generated_file_pull_requests
  }
}
