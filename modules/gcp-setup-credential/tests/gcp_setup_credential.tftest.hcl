# modules/gcp-setup-credential with a mock google provider: no Google Cloud credential and no network call. The
# subjects are the root module's setup_oidc_subjects for vectors/cases/saas-gcp-setup.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_resource "google_iam_workload_identity_pool_provider" {
    defaults = {
      name = "projects/123456789012/locations/global/workloadIdentityPools/acse-setup/providers/github"
    }
  }
}

variables {
  project_id       = "example-project"
  setup_repository = "example-org/acse-setup"
  setup_oidc_subjects = {
    apply = "repo:example-org/acse-setup:environment:acse-setup-apply:job_workflow_ref:example-org/acse-setup/.github/workflows/acse-setup-apply.yml@refs/heads/main"
    plan  = "repo:example-org/acse-setup:ref:refs/heads/main:job_workflow_ref:example-org/acse-setup/.github/workflows/acse-setup-apply.yml@refs/heads/main"
    check = "repo:example-org/acse-setup:pull_request:job_workflow_ref:example-org/acse-setup/.github/workflows/acse-setup-apply.yml@refs/pull/*/merge"
  }
  setup_credential_secret_id      = "acse-setup-app-private-key"
  setup_plan_credential_secret_id = "acse-setup-plan-app-private-key"
  app_key_secret_ids              = ["acse-read-app-private-key", "acse-change-app-private-key"]
}

run "binds_each_job_to_its_exact_subject" {
  command = apply

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_mapping["attribute.acse_job"] == "assertion.sub == '${var.setup_oidc_subjects.apply}' ? 'apply' : (assertion.sub == '${var.setup_oidc_subjects.plan}' ? 'plan' : ((assertion.sub.startsWith('repo:example-org/acse-setup:pull_request:job_workflow_ref:example-org/acse-setup/.github/workflows/acse-setup-apply.yml@refs/pull/') && assertion.sub.endsWith('/merge')) ? 'check' : 'none'))"
    error_message = "apply and plan match their subjects exactly; check matches the pull request subject with only the number free."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == 'example-org/acse-setup' && attribute.acse_job != 'none'"
    error_message = "Only the setup repository's three jobs get a token exchanged at all."
  }
  assert {
    condition     = length(google_iam_workload_identity_pool_provider.github.attribute_mapping["google.subject"]) < 127 && jsonencode(google_iam_workload_identity_pool_provider.github.oidc[0].allowed_audiences) == jsonencode(["acse-setup-gcp"])
    error_message = "google.subject stays under 127 bytes; the audience is the template's acse-setup-gcp."
  }
  assert {
    condition = (
      google_secret_manager_secret_iam_member.reader["apply/acse-setup-app-private-key"].member == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/acse-setup/attribute.acse_job/apply"
      && google_secret_manager_secret_iam_member.reader["plan/acse-setup-plan-app-private-key"].member == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/acse-setup/attribute.acse_job/plan"
      && google_secret_manager_secret_iam_member.reader["apply/acse-read-app-private-key"].member == output.principals.apply
      && google_secret_manager_secret_iam_member.reader["apply/acse-change-app-private-key"].member == output.principals.apply
    )
    error_message = "Only apply reads the setup key and the ACSE App keys; only plan reads the read-only key."
  }
  assert {
    condition     = length(google_secret_manager_secret_iam_member.reader) == 4 && length([for r in google_secret_manager_secret_iam_member.reader : r if r.member == output.principals.check]) == 0
    error_message = "The check job reads no secret."
  }
  assert {
    condition     = length(google_project_iam_member.job) == 6 && output.workload_identity_provider == "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/acse-setup/providers/github"
    error_message = "Two project roles per job by default; the provider name is the external_account audience."
  }
}

run "refuses_subjects_that_are_not_the_modules" {
  command = plan

  variables {
    setup_oidc_subjects = {
      apply = "repo:example-org/acse-setup:environment:acse-setup-apply"
      plan  = "repo:example-org/acse-setup:ref:refs/heads/main"
      check = "repo:example-org/acse-setup:pull_request"
    }
  }

  expect_failures = [google_iam_workload_identity_pool_provider.github]
}
