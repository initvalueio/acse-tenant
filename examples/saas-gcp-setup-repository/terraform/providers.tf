# Credentials, all by identity: no GitHub secret, no GitHub variable, and no AWS sign-in in this root.
#
# Google Cloud: the workflow's OIDC token for audience acse-setup-gcp (TF_VAR_acse_gcp_web_identity_token_file, from
# template 1.1.0), exchanged at Google's STS through the pool modules/gcp-setup-credential creates. There is one
# provider for all three jobs; the token's sub decides what it may do (attribute.acse_job):
#   check -> broad read, no secret, and NO GitHub credential (SC-5);
#   plan  -> broad read, and only the read-only App's key;
#   apply -> the setup App's key and the ACSE Read and Change keys it puts into InitValue's namespace.
# The very first apply (bootstrap, T-8) runs before the pool exists: run it once as a project owner with
# use_web_identity = false and your own Application Default Credentials. It does not publish (the publish role trusts
# only the workflow's apply job); the workflow's first apply does.
#
# GitHub, by phase: check none; plan your read-only App; apply your setup App. Each key is read through an ephemeral
# resource, so it never reaches state or the plan file (Terraform >= 1.10).

locals {
  github_app = {
    check = null
    plan  = var.plan_app
    apply = var.setup_app
  }[var.acse_setup_phase]

  # The ACSE Read and Change keys, read only in the apply phase and only when the version label is set.
  acse_app_key_ids = var.acse_setup_phase == "apply" && var.acse_app_keys.version != null ? {
    read   = var.acse_app_keys.read_secret_id
    change = var.acse_app_keys.change_secret_id
  } : {}
}

provider "google" {
  project = var.gcp_project_id

  # An external_account credential: Google's STS exchanges the GitHub token directly, with no service account.
  credentials = var.use_web_identity ? jsonencode({
    type               = "external_account"
    audience           = var.gcp_workload_identity_provider
    subject_token_type = "urn:ietf:params:oauth:token-type:jwt"
    token_url          = "https://sts.googleapis.com/v1/token"
    credential_source  = { file = var.acse_gcp_web_identity_token_file }
  }) : null
}

ephemeral "google_secret_manager_secret_version" "github_app_key" {
  count  = local.github_app == null ? 0 : 1
  secret = local.github_app.private_key_secret_id
}

ephemeral "google_secret_manager_secret_version" "acse_app_key" {
  for_each = local.acse_app_key_ids
  secret   = each.value
}

provider "github" {
  owner = split("/", local.tenant.repositories.setup)[0]

  dynamic "app_auth" {
    for_each = local.github_app == null ? [] : [1]
    content {
      id              = local.github_app.id
      installation_id = local.github_app.installation_id
      pem_file        = ephemeral.google_secret_manager_secret_version.github_app_key[0].secret_data
    }
  }
}
