# A GCP-hosted setup credential (spec 02e Amendment 6 SA-5), in a DEDICATED setup project (Koushik, 2026-11-07:
# "I prefer Dedicated Project, broad roles..... but also ensure the promoter keu for outbox tenants also lives here in
# this project"). The project holds only:
#   - this workload identity pool and its providers;
#   - the setup App's key and the read-only plan App's key;
#   - in SaaS mode, the ACSE Read and Change App keys the apply puts into InitValue's namespace;
#   - for Outbox tenants, the promoter App's key.
# Nothing else. The apply job gets roles/editor and roles/iam.securityAdmin on this project only: broad roles, but
# the blast radius is one otherwise empty project. Terraform cannot check that the project holds nothing else, so the
# customer confirms it (gcp_setup_project_is_dedicated).
#
# No service account: secrets are granted to federated principal sets directly. Which job a token belongs to is
# decided by its exact claims, mapped to attribute.acse_job. google.subject is limited to 127 bytes, shorter than
# these subjects, so it carries the run instead, for audit logs.
#
#   provider "github" (setup repository, audience acse-setup-gcp):
#     apply -- reads the setup App's key and app_key_secret_ids; roles/editor + roles/iam.securityAdmin on the project.
#     plan  -- reads only the read-only App's key; plan_project_roles (broad read).
#     check -- reads no secret; check_project_roles (broad read).
#   provider "github-promoter" (outbox repository, audience acse-promote-gcp), only when promoter is set:
#     promote -- acse-promote.yml on the outbox's default branch. Reads exactly the promoter key; no project role.
# A token that maps to none of these is refused by its provider's condition, so it gets no access at all.
#
# Secret Manager IAM only allows; there is no resource-level deny as on AWS. That is why the project must be
# dedicated: nobody else may hold a project-level role in it.

locals {
  project   = var.gcp_setup_project
  pool_name = "projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.pool_id}"

  # Exact match for apply and plan; for check, the fixed prefix up to refs/pull/ and the fixed suffix /merge, as the
  # AWS check role's StringLike (only the pull request number varies).
  check_prefix = trimsuffix(var.setup_oidc_subjects.check, "*/merge")
  acse_job_expression = join("", [
    "assertion.sub == '${var.setup_oidc_subjects.apply}' ? 'apply' : ",
    "(assertion.sub == '${var.setup_oidc_subjects.plan}' ? 'plan' : ",
    "((assertion.sub.startsWith('${local.check_prefix}') && assertion.sub.endsWith('/merge')) ? 'check' : 'none'))",
  ])

  # The promoter: its sub (as its AWS role trusts it) and, whatever the outbox's subject template, the workflow file
  # and branch from the job_workflow_ref claim.
  promoter_job_expression = var.promoter == null ? null : join("", [
    "(assertion.sub == '${var.promoter.subject}' && assertion.job_workflow_ref == '${var.promoter.job_workflow_ref}') ? 'promote' : 'none'",
  ])

  principal = { for job in ["apply", "plan", "check", "promote"] : job => "principalSet://iam.googleapis.com/${local.pool_name}/attribute.acse_job/${job}" }

  # Fixed for apply (the decision); never org-wide, never another project.
  apply_project_roles = ["roles/editor", "roles/iam.securityAdmin"]

  project_roles = merge(
    { for role in local.apply_project_roles : "apply/${role}" => { job = "apply", role = role } },
    { for role in var.plan_project_roles : "plan/${role}" => { job = "plan", role = role } },
    { for role in var.check_project_roles : "check/${role}" => { job = "check", role = role } },
  )

  # Secret ids as given (short name or projects/<project>/secrets/<name>) => short name.
  short = { for id in distinct(compact(concat(
    [var.setup_credential_secret_id, var.setup_plan_credential_secret_id],
    var.app_key_secret_ids,
    [var.promoter == null ? "" : var.promoter.secret_id],
  ))) : id => element(split("/", id), length(split("/", id)) - 1) }

  secret_readers = merge(
    { "apply/${local.short[var.setup_credential_secret_id]}" = { job = "apply", secret = local.short[var.setup_credential_secret_id] } },
    { "plan/${local.short[var.setup_plan_credential_secret_id]}" = { job = "plan", secret = local.short[var.setup_plan_credential_secret_id] } },
    { for id in var.app_key_secret_ids : "apply/${local.short[id]}" => { job = "apply", secret = local.short[id] } },
    var.promoter == null ? {} : { "promote/${local.short[var.promoter.secret_id]}" = { job = "promote", secret = local.short[var.promoter.secret_id] } },
  )

  # Every secret id must be in the dedicated project; the promoter key must be none of the others.
  ids_in_project = alltrue([for id, _ in local.short : !strcontains(id, "/") || startswith(id, "projects/${local.project}/secrets/")])
  promoter_key_apart = var.promoter == null || !contains(
    [for id in concat([var.setup_credential_secret_id, var.setup_plan_credential_secret_id], var.app_key_secret_ids) : local.short[id]],
    try(local.short[var.promoter.secret_id], ""),
  )
}

data "google_project" "this" {
  project_id = local.project
}

resource "google_iam_workload_identity_pool" "setup" {
  project                   = local.project
  workload_identity_pool_id = var.pool_id
  display_name              = "ACSE setup"
  description               = "acse-setup-apply.yml in ${var.setup_repository}${var.promoter == null ? "" : ", and acse-promote.yml in ${var.promoter.repository}"}. Dedicated project."

  lifecycle {
    precondition {
      condition     = var.gcp_setup_project_is_dedicated
      error_message = "gcp_setup_project must be a DEDICATED project that holds only this pool and the setup, plan, ACSE App and promoter keys, and nothing else: the apply job gets roles/editor and roles/iam.securityAdmin on it, and Secret Manager has no deny. Terraform cannot verify that. Confirm it with gcp_setup_project_is_dedicated = true."
    }
    precondition {
      condition     = local.ids_in_project && local.promoter_key_apart
      error_message = "Every secret must be in gcp_setup_project (${local.project}), and the promoter's key must be its own secret, not the setup, plan or ACSE App key."
    }
  }
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = local.project
  workload_identity_pool_id          = google_iam_workload_identity_pool.setup.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub Actions: setup"
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

resource "google_iam_workload_identity_pool_provider" "promoter" {
  count = var.promoter == null ? 0 : 1

  project                            = local.project
  workload_identity_pool_id          = google_iam_workload_identity_pool.setup.workload_identity_pool_id
  workload_identity_pool_provider_id = var.promoter_provider_id
  display_name                       = "GitHub Actions: promoter"
  description                        = "acse-promote.yml in ${var.promoter.repository}; audience ${var.promoter_audience}."

  attribute_mapping = {
    "google.subject"     = "assertion.repository_id + ':' + assertion.run_id + ':' + assertion.run_attempt"
    "attribute.acse_job" = local.promoter_job_expression
  }
  attribute_condition = "assertion.repository == '${var.promoter.repository}' && attribute.acse_job == 'promote'"

  oidc {
    issuer_uri        = "https://token.actions.githubusercontent.com"
    allowed_audiences = [var.promoter_audience]
  }

  lifecycle {
    precondition {
      condition     = !strcontains(var.promoter.subject, "'") && !strcontains(var.promoter.job_workflow_ref, "'") && strcontains(var.promoter.job_workflow_ref, "/.github/workflows/acse-promote.yml@refs/heads/")
      error_message = "promoter must be the acse-tenant module's promoter_oidc output (plus secret_id): acse-promote.yml on the outbox's default branch."
    }
  }
}

resource "google_project_iam_member" "job" {
  for_each = local.project_roles

  project = local.project
  role    = each.value.role
  member  = local.principal[each.value.job]
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = local.secret_readers

  project   = local.project
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = local.principal[each.value.job]
}
