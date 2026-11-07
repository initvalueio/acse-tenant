# A GCP-hosted setup credential (spec 02e Amendment 6 SA-5): the customer's setup App key, read-only App key and, in
# SaaS mode, the ACSE Read and ACSE Change App keys stay in the customer's own Google Cloud Secret Manager, reached by
# acse-setup-apply.yml through Workload Identity Federation. It is the GCP form of setup.tf's three AWS roles.
#
# One pool and one GitHub OIDC provider. No service account: the secrets are granted to federated principals
# directly. Which job a token belongs to is decided by its exact sub, the same SC-1 subjects the AWS roles trust, taken
# from the root module's setup_oidc_subjects output:
#   attribute.acse_job = "apply" | "plan" | "check" | "none"
# A token whose sub is none of the three is refused by the provider's condition, so it gets no access at all.
# google.subject is limited to 127 bytes, shorter than these subjects, so it carries the run instead, for audit logs.
#
#   apply -- reads the setup App's key and the app_key_secret_ids (SaaS: the ACSE Read and Change keys it puts in
#            InitValue's namespace). apply_project_roles on the project, so it can maintain this module's own resources.
#   plan  -- reads only the read-only App's key. plan_project_roles (broad read).
#   check -- reads no secret. check_project_roles (broad read).
#
# Secret Manager IAM only allows; there is no resource-level deny as on AWS. So the guarantee is "only these principals
# are granted here": keep the secrets in a project where nobody else holds a project-level accessor or owner role.

locals {
  pool_name = "projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.pool_id}"

  # Exact match for apply and plan; for check, the fixed prefix up to refs/pull/ and the fixed suffix /merge, as the
  # AWS check role's StringLike (only the pull request number varies).
  check_prefix = trimsuffix(var.setup_oidc_subjects.check, "*/merge")
  acse_job_expression = join("", [
    "assertion.sub == '${var.setup_oidc_subjects.apply}' ? 'apply' : ",
    "(assertion.sub == '${var.setup_oidc_subjects.plan}' ? 'plan' : ",
    "((assertion.sub.startsWith('${local.check_prefix}') && assertion.sub.endsWith('/merge')) ? 'check' : 'none'))",
  ])

  principal = { for job in ["apply", "plan", "check"] : job => "principalSet://iam.googleapis.com/${local.pool_name}/attribute.acse_job/${job}" }

  project_roles = merge(
    { for role in var.apply_project_roles : "apply/${role}" => { job = "apply", role = role } },
    { for role in var.plan_project_roles : "plan/${role}" => { job = "plan", role = role } },
    { for role in var.check_project_roles : "check/${role}" => { job = "check", role = role } },
  )

  secret_readers = merge(
    { "apply/${var.setup_credential_secret_id}" = { job = "apply", secret = var.setup_credential_secret_id } },
    { "plan/${var.setup_plan_credential_secret_id}" = { job = "plan", secret = var.setup_plan_credential_secret_id } },
    { for id in var.app_key_secret_ids : "apply/${id}" => { job = "apply", secret = id } },
  )
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_iam_workload_identity_pool" "setup" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "ACSE setup"
  description               = "acse-setup-apply.yml in ${var.setup_repository}: apply, plan and check jobs only."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.setup.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub Actions"
  description                        = "GitHub OIDC for ${var.setup_repository}; audience ${var.audience}."

  attribute_mapping = {
    "google.subject"     = "assertion.repository_id + ':' + assertion.run_id + ':' + assertion.run_attempt"
    "attribute.acse_job" = local.acse_job_expression
  }
  attribute_condition = "assertion.repository == '${var.setup_repository}' && attribute.acse_job != 'none'"

  oidc {
    issuer_uri        = "https://token.actions.githubusercontent.com"
    allowed_audiences = [var.audience]
  }

  lifecycle {
    precondition {
      condition     = alltrue([for s in values(var.setup_oidc_subjects) : !strcontains(s, "'")]) && endswith(var.setup_oidc_subjects.check, "*/merge")
      error_message = "setup_oidc_subjects must be the acse-tenant module's setup_oidc_subjects output."
    }
  }
}

resource "google_project_iam_member" "job" {
  for_each = local.project_roles

  project = var.project_id
  role    = each.value.role
  member  = local.principal[each.value.job]
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = local.secret_readers

  project   = var.project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = local.principal[each.value.job]
}
