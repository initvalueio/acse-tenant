output "tenant" {
  description = "The tenant id (tenant.yaml tenant)."
  value       = local.tenant
}

output "namespace" {
  description = "The namespace, acse/<tenant>."
  value       = local.namespace
}

output "boundary" {
  description = "The naming boundary's first segment, {prefix}acse{suffix}."
  value       = local.boundary
}

output "secret_names" {
  description = "Namespace-relative path => Secrets Manager secret name, for every secret this module created (containers only; no value)."
  value       = local.secret_names
}

output "secret_arns" {
  description = "Namespace-relative path => secret ARN. Give the ACSE runtime's role GetSecretValue on these (02e section 4)."
  value       = { for path, secret in aws_secretsmanager_secret.namespace : path => secret.arn }
}

output "settings_parameter_names" {
  description = "Section => SSM parameter name (/acse/<tenant>/settings/<section>)."
  value       = local.settings_names
}

output "settings_index_values" {
  description = "Section => the settings-index-1.0 document published at settings/<section>."
  value       = local.settings_index
}

output "settings_part_names" {
  description = "<section>/<i> => SSM parameter name of a part, for sections too large to go inline."
  value       = local.settings_part_names
}

output "settings_part_values" {
  description = "<section>/<i> => the part's value: a slice of the section's payload."
  value       = local.settings_parts
}

output "settings_payloads" {
  description = "Section => the payload: the section as written in tenant.yaml, as jsonencode renders it (its sha256 is the index's sha256)."
  value       = local.settings
}

output "evidence_public_key_parameter_name" {
  description = "The SSM parameter keygen writes. This module never creates or writes it."
  value       = local.evidence_public_key_name
}

output "parameter_arn_prefix" {
  description = "arn:aws:ssm:<region>:<account>:parameter/acse/<tenant>: the prefix of every parameter in the namespace."
  value       = local.parameter_arn_prefix
}

output "oidc_provider_arn" {
  description = "The GitHub OIDC provider the promoter role trusts."
  value       = local.oidc_provider_arn
}

output "promoter_role_arn" {
  description = "cloud.workflow_role (Outbox tenants), or null."
  value       = local.has_outbox ? local.promoter_role_arn : null
}

output "promoter_trust_subject" {
  description = "The exact OIDC sub the promoter role trusts, or null."
  value       = local.promoter_subject
}

output "promoter_trust_policy" {
  description = "The promoter role's trust policy JSON, or null."
  value       = local.promoter_trust_policy
}

output "promoter_read_policy" {
  description = "The promoter role's only permissions policy JSON, or null."
  value       = local.promoter_read_policy
}

output "promoter_store_reads" {
  description = "The four store entries the promoter reads: the three parameter names and the one secret name. secret is null in SaaS mode with a GCP setup project, where the key is in that project (promoter_oidc.key_in_gcp)."
  value = local.has_outbox ? {
    parameters = local.promoter_parameter_names
    secret     = try(local.secret_names["outbox/promoter/private-key"], null)
  } : null
}

output "setup_oidc_subjects" {
  description = "SC-1: the exact OIDC sub of each acse-setup-apply.yml job under the setup repository's subject template. apply and plan are matched exactly; check is the pull request's subject, where * stands for the pull request number. modules/gcp-setup-credential binds these when setup_credential_store = gcp. Null when no setup credential is configured."
  value = local.setup_enabled ? {
    apply = local.setup_apply_subject
    plan  = local.setup_plan_subject
    check = local.setup_check_subject
  } : null
}

output "promoter_oidc" {
  description = "Outbox tenants: what acse-promote.yml's OIDC token carries, for modules/gcp-setup-credential's promoter mapping. key_in_gcp is true in SaaS mode with setup_credential_store = gcp: the promoter's App key then lives in the dedicated GCP setup project, not in the namespace. Null without an outbox."
  value = local.has_outbox ? {
    repository       = local.outbox_full
    subject          = local.promoter_subject
    job_workflow_ref = local.promoter_workflow_ref
    key_in_gcp       = local.promoter_key_in_gcp
  } : null
}

output "gcp_setup_project" {
  description = "The dedicated GCP setup project (setup_credential_store = gcp), or null."
  value       = local.setup_gcp ? var.gcp_setup_project : null
}

output "saas" {
  description = "SaaS mode (spec 02e Amendment 6 section A), or null when self-hosted. publish_policy and publish_trust_policy are what InitValue's pipeline gives the per-tenant publish role (SA-1, SA-2); the module itself never creates it. skipped lists what this mode does not create."
  value = local.saas ? {
    publish_role_arn      = var.saas_publish_role_arn
    publish_on_apply      = var.saas_publish_on_apply
    publish_trust_subject = local.setup_apply_subject
    publish_trust_policy  = local.saas_publish_trust_policy
    publish_policy        = local.saas_publish_policy
    published_parameters  = local.saas_slots
    app_key_secret_names  = local.saas_app_key_secret_names
    app_keys_version      = var.saas_app_keys_version
    skipped               = ["namespace", "github_oidc_provider", "promoter_role"]
  } : null
}

output "setup_roles" {
  description = "DEC-20: the setup apply role (the only reader of the setup credential), the post-merge plan role (the only reader of the read-only App's key) and the PR-check role, their trusted subjects and policies, and the environment; null unless setup_credential_store is aws and setup_credential_secret_arn is set."
  value = local.setup_aws ? {
    apply_role_arn     = local.setup_apply_arn
    apply_subject      = local.setup_apply_subject
    apply_environment  = var.setup_apply_environment
    plan_role_arn      = local.setup_plan_arn
    plan_subject       = local.setup_plan_subject
    plan_trust_policy  = local.setup_plan_trust_policy
    plan_secret_policy = local.setup_plan_credential_policy
    check_role_arn     = local.setup_check_arn
    check_subject      = local.setup_check_subject
    apply_trust_policy = local.setup_apply_trust_policy
    check_trust_policy = local.setup_check_trust_policy
    credential_policy  = local.setup_credential_policy
  } : null
}

output "pr_plan_targets" {
  description = "SC-5: the cloud-side resource addresses (relative to this module) that the pull request's plan targets. acse-setup-apply.yml carries the same list for a module call named acse_tenant."
  value = [
    "terraform_data.tenant_config",
    "aws_secretsmanager_secret.namespace",
    "aws_ssm_parameter.settings_part",
    "aws_ssm_parameter.settings",
    "aws_iam_openid_connect_provider.github",
    "aws_iam_role.promoter",
    "aws_iam_role_policy.promoter_reads",
    "aws_iam_role.setup_apply",
    "aws_iam_role_policy_attachment.setup_apply",
    "aws_iam_role.setup_plan",
    "aws_iam_role_policy_attachment.setup_plan",
    "aws_secretsmanager_secret_policy.setup_plan_credential",
    "aws_iam_role.setup_check",
    "aws_iam_role_policy_attachment.setup_check",
    "aws_secretsmanager_secret_policy.setup_credential",
  ]
}

output "branch_ruleset_exclude" {
  description = "The branch ruleset's one exclusion, refs/heads/<boundary>/**."
  value       = local.boundary_ref
}

output "ruleset_ids" {
  description = "The three organization rulesets' ids."
  value = {
    branches      = github_organization_ruleset.branches.ruleset_id
    no_force_push = github_organization_ruleset.boundary_no_force_push.ruleset_id
    tags          = github_organization_ruleset.tags.ruleset_id
  }
}

output "generated_files" {
  description = "Key (gate, promoter) => repository, path, schema and the exact file content generated from tenant.yaml."
  value = {
    for key, file in local.generated_files : key => {
      repository = file.full_name
      branch     = file.default_branch
      path       = file.path
      schema     = file.schema
      content    = local.generated_content[key]
    }
  }
}

output "generated_file_pull_requests" {
  description = "Key => the pull request opened for a generated file that differs from its default branch (pull_request mode)."
  value       = { for key, pr in github_repository_pull_request.generated : key => { repository = local.generated_files[key].full_name, number = pr.number, branch = pr.head_ref } }
}
