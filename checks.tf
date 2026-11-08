# The PR-time warning for gate repositories ACSE Read cannot see (spec 02e Amendment 3 item 5; ADR-0085 Amendment 2
# A2.5; GA-4 as restated by GA-19; GA-26). A check block: it warns in the plan of the setup repository's PR and never
# fails it, and a failed read is a warning too.
#
# How it learns visibility: GET /orgs/{org}/installations with the setup credential, then ACSE Read's installation
# (github.read_app_id). repository_selection "all" settles it for repositories in the organization. "selected" cannot
# be resolved with the customer's credential, so it warns "could not check" (GA-26). No installation, or a repository
# in another organization: not visible. Whether a listed repository exists is not checked here.

locals {
  # GET /meta when the warning is off or nothing is listed, so the scoped read never needs organization access.
  installations_endpoint = var.warn_unseen_gate_repositories && length(local.gate_repositories) > 0 ? "orgs/${local.org}/installations?per_page=100" : "meta"
  gate_repo_label        = { for r in local.gate_repositories : r => lower(split("/", r)[0]) == lower(local.org) ? split("/", r)[1] : r }
}

check "gate_repositories_visible_to_acse_read" {
  data "github_rest_api" "installations" {
    endpoint = local.installations_endpoint
  }

  assert {
    condition = local.installations_endpoint == "meta" || try(data.github_rest_api.installations.code, 0) != 200 || length([
      for r in local.gate_repositories : r
      if lower(split("/", r)[0]) != lower(local.org) || !contains(
        [for i in try(jsondecode(data.github_rest_api.installations.body).installations, []) : tostring(i.app_id) if try(i.repository_selection, "") != ""],
        tostring(local.read_app_id),
      )
    ]) == 0
    error_message = join("\n", [
      for r in local.gate_repositories : "${local.gate_repo_label[r]} is not visible to ACSE Read; its gate reports will wait until it's added to the installation."
      if lower(split("/", r)[0]) != lower(local.org) || !contains(
        [for i in try(jsondecode(data.github_rest_api.installations.body).installations, []) : tostring(i.app_id) if try(i.repository_selection, "") != ""],
        tostring(local.read_app_id),
      )
    ])
  }

  assert {
    condition = local.installations_endpoint == "meta" || try(data.github_rest_api.installations.code, 0) != 200 || !contains(
      [for i in try(jsondecode(data.github_rest_api.installations.body).installations, []) : tostring(i.app_id) if try(i.repository_selection, "") == "selected"],
      tostring(local.read_app_id),
    )
    error_message = join("\n", [
      for r in local.gate_repositories : "Could not check whether ${local.gate_repo_label[r]} is visible to ACSE Read: its installation on ${local.org} uses a selected repository list. If ${local.gate_repo_label[r]} is not on it, its gate reports will wait until it's added to the installation."
      if lower(split("/", r)[0]) == lower(local.org)
    ])
  }

  assert {
    condition     = local.installations_endpoint == "meta" || try(data.github_rest_api.installations.code, 0) == 200
    error_message = "Could not check which gate repositories ACSE Read can see: GET /orgs/${local.org}/installations answered ${try(data.github_rest_api.installations.status, "nothing")}. The setup credential needs organization administration read for this warning; nothing else depends on it."
  }
}

# DEC-29: the repo segment the roles' trusts pin must be the one GitHub puts in sub. Repositories created after
# 2026-07-15 use the immutable format (owner@id/name@id) by default. GitHub reports the repository's prefix as
# sub_claim_prefix (GET /repos/{owner}/{repo}/actions/oidc/customization/sub). Its exact shape is not documented, so
# this warns on a mismatch and never fails; a wrong segment fails closed (the role cannot be assumed). It reads with
# the apply phase's credential; the pull request's cloud-only plan does not evaluate it.
check "setup_oidc_subject_repo_matches_github" {
  data "github_rest_api" "setup_sub" {
    endpoint = local.setup_enabled ? "repos/${local.setup_full}/actions/oidc/customization/sub" : "meta"
  }

  assert {
    condition = (
      !local.setup_enabled
      || try(data.github_rest_api.setup_sub.code, 0) != 200
      || try(jsondecode(data.github_rest_api.setup_sub.body).sub_claim_prefix, null) == null
      || try(jsondecode(data.github_rest_api.setup_sub.body).sub_claim_prefix, "") == "repo:${local.setup_sub_repo}"
    )
    error_message = "GitHub reports the setup repository's OIDC sub prefix as ${try(jsondecode(data.github_rest_api.setup_sub.body).sub_claim_prefix, "?")}, but the setup roles trust repo:${local.setup_sub_repo}. Set setup_oidc_subject_repo to match, or the workflow cannot assume either role."
  }
}

check "outbox_oidc_subject_repo_matches_github" {
  data "github_rest_api" "outbox_sub" {
    endpoint = local.has_outbox ? "repos/${local.outbox_full}/actions/oidc/customization/sub" : "meta"
  }

  assert {
    condition = (
      !local.has_outbox
      || try(data.github_rest_api.outbox_sub.code, 0) != 200
      || try(jsondecode(data.github_rest_api.outbox_sub.body).sub_claim_prefix, null) == null
      || try(jsondecode(data.github_rest_api.outbox_sub.body).sub_claim_prefix, "") == "repo:${local.outbox_sub_repo}"
    )
    error_message = "GitHub reports the outbox repository's OIDC sub prefix as ${try(jsondecode(data.github_rest_api.outbox_sub.body).sub_claim_prefix, "?")}, but the promoter role trusts repo:${local.outbox_sub_repo == null ? "" : local.outbox_sub_repo}. Set outbox_oidc_subject_repo to match, or the promoter cannot assume its role."
  }
}

# DEC-48: in SaaS mode with a GCP setup project the promoter key is in that project, never in the namespace (DEC-47),
# so .github/acse-promote.json must tell the promoter so: outbox.promoter_key.store gcp_secret_manager, which makes the
# file promoter-config-1.1. A warning, never a failure: the values come from modules/gcp-setup-credential's outputs,
# which exist only after the first apply that creates the promoter's provider, and failing the plan would block it.
check "promoter_key_named_in_tenant_yaml" {
  assert {
    condition     = !local.promoter_key_in_gcp || local.promoter_key_gcp
    error_message = "The promoter's App key is in the GCP setup project, but tenant.yaml does not set outbox.promoter_key.store: gcp_secret_manager, so .github/acse-promote.json stays promoter-config-1.0 and the promoter looks for its key in the namespace, where there is none. Copy modules/gcp-setup-credential's outputs promoter_workload_identity_provider, promoter_key_secret_name and promoter_audience into outbox.promoter_key (tenant-config-1.3)."
  }
}
