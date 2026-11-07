# What this module checks in tenant.yaml before it changes anything: the members it depends on, against
# tenant-config-1.2 and promoter-config-1.0 / gate-config-1.0. Every failure stops the plan. The runtime's validation
# (lane LR-2, contracts/tooling/acse_tenant_config.py and the governed vectors) remains the full schema check.

# AWS is signed in only where this module creates something in AWS: always when self-hosted; in SaaS mode only when
# the setup roles are in your own AWS account. A SaaS tenant with a GCP-hosted setup credential needs no AWS sign-in
# at plan time at all (the publish step signs in by itself, on apply).
data "aws_caller_identity" "current" {
  count = local.aws_signed_in ? 1 : 0
}

data "aws_region" "current" {
  count = local.saas ? 0 : 1
}

locals {
  repo_pattern           = "^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$"
  listed_repos           = compact([try(tostring(local.repositories.setup), ""), try(tostring(local.repositories.policies), ""), try(tostring(local.repositories.outbox), "")])
  settings_parts_cap     = 64
  settings_over_cap      = [for section, n in local.settings_parts_count : section if n > local.settings_parts_cap]
  settings_part_too_long = [for key, n in local.settings_part_bytes : key if n > 7168]
  promoter_not_inline    = [for section in ["outbox", "naming"] : section if local.has_outbox && try(local.settings_parts_count[section], 0) != 0]
  read_app_id            = try(tonumber(local.config.github.read_app_id), 0)
  change_app_id          = try(tonumber(local.config.github.change_app_id), 0)

  aws_signed_in    = !local.saas || local.setup_aws
  aws_account_want = local.saas ? local.setup_account : local.account
  aws_account_seen = try(data.aws_caller_identity.current[0].account_id, local.aws_account_want)
  aws_region_seen  = try(data.aws_region.current[0].region, local.region)
  saas_role_match  = local.saas ? try(regex("^arn:aws:iam::([0-9]{12}):role/", var.saas_publish_role_arn)[0], "") : ""
}

resource "terraform_data" "tenant_config" {
  input = {
    tenant             = local.tenant
    namespace          = local.namespace
    tenant_yaml_sha256 = local.tenant_yaml_sha256
  }

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", local.tenant))
      error_message = "tenant must match ^[a-z0-9][a-z0-9-]{0,62}$ (the runtime's tenant id, OD-8)."
    }
    precondition {
      condition     = local.namespace == "acse/${local.tenant}"
      error_message = "cloud.namespace must be exactly acse/<tenant> (spec 02e section 3, OD-8); it is ${local.namespace}."
    }
    precondition {
      condition     = try(local.cloud.provider, "") == "aws"
      error_message = "cloud.provider must be aws: this module builds the AWS namespace only (OD-16)."
    }
    precondition {
      condition     = can(regex("^[0-9]{12}$", local.account))
      error_message = "cloud.account must be a 12-digit AWS account id, quoted in YAML."
    }
    precondition {
      condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", local.region))
      error_message = "cloud.region must be an AWS region such as ca-central-1 (promoter-config-1.0's pattern)."
    }
    precondition {
      condition     = local.role_match != null && can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]{1,512}$", local.promoter_role_arn))
      error_message = "cloud.workflow_role must be an IAM role ARN, arn:aws:iam::<12 digits>:role/[path/]<name> (promoter-config-1.0)."
    }
    precondition {
      condition     = local.role_match == null || try(local.role_match[0], "") == local.account
      error_message = "cloud.workflow_role must be in cloud.account (ledger 02e section 10.3, account check)."
    }
    precondition {
      condition     = alltrue([for r in local.listed_repos : can(regex(local.repo_pattern, r))]) && try(local.repositories.setup, null) != null && try(local.repositories.policies, null) != null
      error_message = "repositories.setup and repositories.policies are required, each owner/name (and repositories.outbox when set)."
    }
    precondition {
      condition     = length(distinct([for r in local.listed_repos : lower(split("/", r)[0])])) == 1
      error_message = "repositories.setup, policies and outbox must be in one GitHub organization: the rulesets are that organization's, and the github provider's owner must be it."
    }
    precondition {
      condition     = local.has_outbox == (try(local.config.outbox, null) != null)
      error_message = "tenant.yaml has an outbox section exactly when repositories.outbox is set (tenant-config-1.2)."
    }
    precondition {
      condition     = local.read_app_id >= 1 && local.change_app_id >= 1 && floor(local.read_app_id) == local.read_app_id && floor(local.change_app_id) == local.change_app_id
      error_message = "github.read_app_id and github.change_app_id must be App ids (integers of at least 1)."
    }
    precondition {
      condition     = !contains([for id in var.ruleset_bypass_integration_ids : tonumber(id)], local.change_app_id)
      error_message = "ACSE Change (github.change_app_id) must never be on the rulesets' bypass list (spec 02b section 4 layer 3)."
    }
    precondition {
      condition     = try(local.gate_section.enforcement, "per_repo") == "per_repo"
      error_message = "gate.enforcement ruleset is not available yet (OD-6; the runtime reports ENFORCEMENT_NOT_AVAILABLE). Use per_repo."
    }
    precondition {
      condition     = (local.gate_audience == null) == (local.gate_report_url == null)
      error_message = "gate.audience and gate.report_url are set together: .github/acse-gate.json (gate-config-1.0) needs both."
    }
    precondition {
      condition     = local.gate_audience == null || can(regex("^acse-gate:gta-[0-9a-f]{32}$", local.gate_audience))
      error_message = "gate.audience must be acse-gate:gta-<32 lowercase hex>, as Setup > Access shows it (GA-1)."
    }
    precondition {
      condition     = local.gate_report_url == null || can(regex("^https://[!-~]{1,500}$", local.gate_report_url))
      error_message = "gate.report_url must be an https URL."
    }
    precondition {
      condition = (
        can(regex("^(?:[A-Za-z0-9][A-Za-z0-9-]*-)?$", try(local.naming_section.prefix, "")))
        && can(regex("^(?:-[A-Za-z0-9-]*[A-Za-z0-9])?$", try(local.naming_section.suffix, "")))
        && length(local.boundary) <= 32
      )
      error_message = "naming.prefix must be empty or end with '-', naming.suffix empty or start with '-', and the first segment {prefix}acse{suffix} at most 32 characters (02b Amendment 6, N-6)."
    }
    precondition {
      condition     = length(local.settings_over_cap) == 0
      error_message = "These tenant.yaml sections would need more than ${local.settings_parts_cap} settings parts (about ${local.settings_parts_cap * 7} KB of JSON): ${join(", ", local.settings_over_cap)}. That is far beyond any expected tenant; check the file. See docs/decisions.md (DEC-6)."
    }
    precondition {
      condition     = length(local.settings_part_too_long) == 0
      error_message = "These settings parts would exceed 7168 bytes (characters of more than 4 bytes in the section): ${join(", ", local.settings_part_too_long)}. See docs/decisions.md (DEC-6)."
    }
    precondition {
      condition     = length(local.promoter_not_inline) == 0
      error_message = "settings/outbox and settings/naming must stay inline: the promoter reads them in one GetParameters call and never reads parts. Too large: ${join(", ", local.promoter_not_inline)}."
    }
    precondition {
      condition     = !local.setup_aws || (!strcontains(var.setup_credential_secret_arn, ":secret:${local.namespace}/") && split(":", var.setup_credential_secret_arn)[4] == local.setup_account)
      error_message = "The setup credential's secret must be in cloud.account and outside ${local.namespace}/ (DEC-20): no ACSE identity may ever be able to read it."
    }
    precondition {
      condition = !local.setup_aws || (
        var.setup_plan_credential_secret_arn != null
        && try(!strcontains(var.setup_plan_credential_secret_arn, ":secret:${local.namespace}/") && split(":", var.setup_plan_credential_secret_arn)[4] == local.setup_account, false)
        && var.setup_plan_credential_secret_arn != var.setup_credential_secret_arn
      )
      error_message = "With setup_credential_secret_arn set, setup_plan_credential_secret_arn is required: the read-only App's key, in the same account as the setup App's key (cloud.account when self-hosted), outside ${local.namespace}/, and not the setup App's key."
    }
    precondition {
      condition     = local.setup_gcp == (var.gcp_setup_project != null)
      error_message = "setup_credential_store = gcp requires gcp_setup_project, and only then: a DEDICATED Google Cloud project that holds the workload identity pool, the setup, plan and (Outbox, SaaS) promoter App keys and nothing else. The apply job gets roles/editor and roles/iam.securityAdmin on it. Terraform cannot check that the project holds nothing else; that is your requirement."
    }
    precondition {
      condition     = !local.setup_gcp || (var.setup_credential_secret_arn == null && var.setup_plan_credential_secret_arn == null)
      error_message = "With setup_credential_store = gcp, the App keys are in Google Cloud Secret Manager: leave setup_credential_secret_arn and setup_plan_credential_secret_arn unset (modules/gcp-setup-credential takes their secret ids)."
    }
    precondition {
      condition     = !local.setup_enabled || (var.setup_default_branch != null && length(var.setup_apply_environment_reviewers.users) + length(var.setup_apply_environment_reviewers.teams) > 0)
      error_message = "With setup_credential_secret_arn set or setup_credential_store = gcp, setup_default_branch is required and setup_apply_environment_reviewers must name at least one user or team (SC-1: the apply environment's approval must mean something)."
    }
    precondition {
      condition     = !local.has_outbox || var.outbox_default_branch != null
      error_message = "outbox_default_branch is required for an Outbox tenant: the promoter role trusts that branch only (SC-5: no GitHub lookup at plan time)."
    }
    precondition {
      condition     = !local.setup_enabled || lower(split("/", replace(local.setup_sub_repo, "/@[0-9]+/", ""))[0]) == lower(split("/", local.setup_full)[0]) && lower(replace(split("/", local.setup_sub_repo)[1], "/@[0-9]+$/", "")) == lower(local.setup_name)
      error_message = "setup_oidc_subject_repo must name repositories.setup (owner/name, with or without @ids)."
    }
    precondition {
      condition     = !local.has_outbox || lower(replace(local.outbox_sub_repo, "/@[0-9]+/", "")) == lower(local.outbox_full)
      error_message = "outbox_oidc_subject_repo must name repositories.outbox (owner/name, with or without @ids)."
    }
    precondition {
      condition = !local.setup_aws || (
        length(distinct([var.setup_apply_role_name, var.setup_plan_role_name, var.setup_check_role_name])) == 3
        && length(setintersection(toset([local.setup_apply_arn, local.setup_plan_arn, local.setup_check_arn]), toset(compact([local.has_outbox ? local.promoter_role_arn : "", var.runtime_role_arn == null ? "" : var.runtime_role_arn])))) == 0
        && length(setintersection(toset(var.setup_credential_extra_reader_arns), toset(compact([local.has_outbox ? local.promoter_role_arn : "", var.runtime_role_arn == null ? "" : var.runtime_role_arn, local.setup_check_arn, local.setup_plan_arn])))) == 0
      )
      error_message = "The setup apply, post-merge plan and PR-check roles, cloud.workflow_role (the promoter's) and the runtime's role must be five distinct roles, and no other of them may read the setup credential (DEC-20)."
    }
    precondition {
      condition     = local.aws_account_seen == local.aws_account_want
      error_message = local.saas ? "The AWS provider is authenticated to account ${local.aws_account_seen}, but your setup roles are in ${local.aws_account_want}, the account of setup_credential_secret_arn (SaaS mode: cloud.account is InitValue's)." : "The AWS provider is authenticated to account ${local.aws_account_seen}, but cloud.account is ${local.account}."
    }
    precondition {
      condition     = local.aws_region_seen == local.region
      error_message = "The AWS provider's region is ${local.aws_region_seen}, but cloud.region is ${local.region}."
    }

    # SaaS mode (spec 02e Amendment 6 section A).
    precondition {
      condition     = !local.saas || local.saas_role_match == local.account
      error_message = "saas_publish_role_arn must be in cloud.account: in SaaS mode tenant.yaml's cloud.* names InitValue's runtime account, which holds the namespace and the publish role (SA-4)."
    }
    precondition {
      condition     = !local.saas || local.setup_enabled
      error_message = "SaaS mode needs the setup apply's environment and OIDC subject: the publish role trusts only the apply job's SC-1 subject. Set setup_credential_secret_arn (setup_credential_store = aws) or setup_credential_store = gcp."
    }
    precondition {
      condition     = !local.saas || !var.create_github_oidc_provider
      error_message = "SaaS mode creates no OIDC provider (Amendment 6 A.4): InitValue's runtime account already has one, and the provider your setup roles trust must exist before the workflow can run. Leave create_github_oidc_provider false."
    }
    precondition {
      condition     = !(local.saas && local.setup_aws) || local.setup_account != local.account
      error_message = "In SaaS mode the setup App's key and the setup roles are yours, never in InitValue's runtime account (${local.account}): setup_credential_secret_arn must be in your own AWS account (SA-5)."
    }
    precondition {
      condition     = local.saas || var.saas_app_keys_version == null
      error_message = "saas_app_keys_version is for SaaS mode only. Self-hosted, put the App keys in ${local.namespace}/ with your own pipeline."
    }
  }
}
