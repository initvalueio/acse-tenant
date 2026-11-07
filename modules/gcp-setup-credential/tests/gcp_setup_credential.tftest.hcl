# modules/gcp-setup-credential with a mock google provider: no Google Cloud credential and no network call. The
# subjects are the root module's setup_oidc_subjects for vectors/cases/saas-gcp-setup.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

variables {
  gcp_setup_project              = "example-acse-setup"
  gcp_setup_project_is_dedicated = true
  setup_repository               = "example-org/acse-setup"
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

  override_resource {
    target = google_iam_workload_identity_pool_provider.github
    values = { name = "projects/123456789012/locations/global/workloadIdentityPools/acse-setup/providers/github" }
  }

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
  assert {
    condition = (
      google_project_iam_member.job["apply/roles/editor"].project == "example-acse-setup"
      && google_project_iam_member.job["apply/roles/iam.securityAdmin"].project == "example-acse-setup"
      && length([for m in google_project_iam_member.job : m if m.member == output.principals.apply]) == 2
      && alltrue([for m in google_project_iam_member.job : m.project == "example-acse-setup"])
    )
    error_message = "The apply job gets exactly roles/editor and roles/iam.securityAdmin, on the dedicated project only."
  }
  assert {
    condition     = length(google_iam_workload_identity_pool_provider.promoter) == 0 && output.promoter_workload_identity_provider == null && output.promoter_key_secret_name == null
    error_message = "Without a promoter there is no promoter provider."
  }
}

run "the_promoter_reads_exactly_its_key" {
  command = apply

  variables {
    promoter = {
      repository       = "example-org/acse-outbox"
      subject          = "repo:example-org/acse-outbox:ref:refs/heads/main"
      job_workflow_ref = "example-org/acse-outbox/.github/workflows/acse-promote.yml@refs/heads/main"
      secret_id        = "projects/example-acse-setup/secrets/acse-promoter-app-private-key"
    }
  }

  override_resource {
    target = google_iam_workload_identity_pool_provider.promoter
    values = { name = "projects/123456789012/locations/global/workloadIdentityPools/acse-setup/providers/github-promoter" }
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.promoter[0].attribute_mapping["attribute.acse_job"] == "(assertion.sub == 'repo:example-org/acse-outbox:ref:refs/heads/main' && assertion.job_workflow_ref == 'example-org/acse-outbox/.github/workflows/acse-promote.yml@refs/heads/main') ? 'promote' : 'none'"
    error_message = "The promoter maps only acse-promote.yml on the outbox's default branch."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.promoter[0].attribute_condition == "assertion.repository == 'example-org/acse-outbox' && attribute.acse_job == 'promote'" && jsonencode(google_iam_workload_identity_pool_provider.promoter[0].oidc[0].allowed_audiences) == jsonencode(["acse-promote-gcp"])
    error_message = "The promoter's provider accepts only the outbox repository's promoter token, audience acse-promote-gcp."
  }
  assert {
    condition     = length([for r in google_secret_manager_secret_iam_member.reader : r if r.member == output.principals.promote]) == 1 && google_secret_manager_secret_iam_member.reader["promote/acse-promoter-app-private-key"].member == output.principals.promote
    error_message = "The promoter reads exactly its own key."
  }
  assert {
    condition     = google_secret_manager_secret_iam_member.reader["apply/acse-setup-app-private-key"].member != output.principals.promote && google_secret_manager_secret_iam_member.reader["plan/acse-setup-plan-app-private-key"].member != output.principals.promote && length([for m in google_project_iam_member.job : m if m.member == output.principals.promote]) == 0
    error_message = "The promoter never reads the setup or plan key and holds no project role."
  }
  assert {
    condition     = output.promoter_workload_identity_provider == "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/acse-setup/providers/github-promoter" && output.promoter_key_secret_name == "projects/example-acse-setup/secrets/acse-promoter-app-private-key" && output.promoter_audience == "acse-promote-gcp"
    error_message = "The outputs the core lane and tenant.yaml reference."
  }
}

run "refuses_an_unconfirmed_project" {
  command = plan

  variables {
    gcp_setup_project_is_dedicated = false
  }

  expect_failures = [google_iam_workload_identity_pool.setup]
}

run "refuses_a_secret_in_another_project" {
  command = plan

  variables {
    setup_credential_secret_id = "projects/some-other-project/secrets/acse-setup-app-private-key"
  }

  expect_failures = [google_iam_workload_identity_pool.setup]
}

run "refuses_the_setup_key_as_the_promoter_key" {
  command = plan

  variables {
    promoter = {
      repository       = "example-org/acse-outbox"
      subject          = "repo:example-org/acse-outbox:ref:refs/heads/main"
      job_workflow_ref = "example-org/acse-outbox/.github/workflows/acse-promote.yml@refs/heads/main"
      secret_id        = "acse-setup-app-private-key"
    }
  }

  expect_failures = [google_iam_workload_identity_pool.setup]
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
