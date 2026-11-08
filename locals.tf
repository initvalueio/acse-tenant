# Everything derived from config/tenant.yaml. Each name here is the interface other lanes read from
# vectors/acse-tenant-vectors-1.0.json; change one only together with the vectors.

locals {
  config             = yamldecode(var.tenant_yaml)
  tenant_yaml_sha256 = "sha256:${sha256(var.tenant_yaml)}"

  tenant    = tostring(local.config.tenant)
  cloud     = local.config.cloud
  account   = tostring(local.cloud.account)
  region    = tostring(local.cloud.region)
  namespace = tostring(local.cloud.namespace) # acse/<tenant>, checked in validation.tf

  # -- the mode (spec 02e Amendment 6 section A) ----------------------------------------------------------------
  # Self-hosted: the namespace is in cloud.account, the customer's own, and this module creates it.
  # SaaS: cloud.account is InitValue's runtime account (SA-4). This module creates nothing there; it publishes
  # settings/* and the App keys write-only through saas_publish_role_arn (saas.tf).
  saas         = var.saas_publish_role_arn != null
  saas_publish = local.saas && var.saas_publish_on_apply
  # SaaS with a GCP setup project: the promoter's App key lives in that dedicated project, read by acse-promote.yml
  # through its own WIF principal, and never in InitValue's namespace (Koushik, 2026-11-07; SA-6 as amended).
  promoter_key_in_gcp = local.saas && var.setup_credential_store == "gcp" && local.has_outbox

  # -- repositories ---------------------------------------------------------------------------------------------
  repositories  = local.config.repositories
  has_outbox    = try(local.repositories.outbox, null) != null
  org           = split("/", local.repositories.setup)[0]
  policies_name = split("/", local.repositories.policies)[1]
  outbox_full   = local.has_outbox ? try(tostring(local.repositories.outbox), null) : null
  outbox_name   = local.has_outbox ? try(split("/", local.repositories.outbox)[1], null) : null

  # -- naming: the boundary (02b Amendment 6 rule 2; 02d A-4) ----------------------------------------------------
  naming_section = try(local.config.naming, {})
  boundary       = "${try(local.naming_section.prefix, "")}acse${try(local.naming_section.suffix, "")}"
  boundary_ref   = "refs/heads/${local.boundary}/**"

  # -- gate ---------------------------------------------------------------------------------------------------
  gate_section        = try(local.config.gate, {})
  gate_audience       = try(tostring(local.gate_section.audience), null)
  gate_report_url     = try(tostring(local.gate_section.report_url), null)
  gate_config_enabled = local.gate_audience != null && local.gate_report_url != null
  gate_repositories   = [for entry in try(local.gate_section.registered_repositories, []) : tostring(entry.repo)]

  # -- the namespace (spec 02e section 3) ---------------------------------------------------------------------
  # Secrets: Secrets Manager names, no leading slash. This module creates each container and never a version:
  # Terraform refreshes a managed version by reading its value, which would make every plan read the App keys.
  secret_paths = merge(
    {
      "github/read/private-key"   = "The private key (PEM) of the customer's GitHub App ACSE Read. Put in by the customer's pipeline; read by the ACSE runtime (IAM)."
      "github/change/private-key" = "The private key (PEM) of the customer's GitHub App ACSE Change. Put in by the customer's pipeline; read by the ACSE runtime (IAM)."
      "evidence/seal-key/current" = "The ACSE runtime's current evidence seal key. Written by keygen; read by the runtime."
      "evidence/seal-key/next"    = "The ACSE runtime's next evidence seal key, set during a rotation. Written by keygen; read by the runtime."
      "tfc/token"                 = "A read-only Terraform Cloud/Enterprise team token. Put in by the customer's pipeline; read by the runtime."
    },
    local.has_outbox && !local.promoter_key_in_gcp ? {
      "outbox/promoter/private-key" = "The private key (PEM) of the customer's promoter GitHub App. Put in by the customer's pipeline; read by acse-promote.yml through cloud.workflow_role (OIDC)."
    } : {},
  )
  secret_names = { for path, _ in local.secret_paths : path => "${local.namespace}/${path}" }

  # Parameters: SSM names need a leading slash once they contain one. The ARN drops it after "parameter".
  parameter_prefix = "/${local.namespace}"

  # settings/<section> is always an index (settings-index-1.0; DEC-6, the Architecture Owner 2026-11-07). The payload is the
  # section's JSON exactly as written in the file (not normalised; AC-5). Top-level scalars (tenant, version) are not
  # sections. naming is always published, {} when absent, because the promoter's narrow role reads it.
  #   inline: the whole index document is <= 8192 bytes -> parts = 0 and the section rides in "inline";
  #   split:  otherwise -> parts = n and the payload is cut into settings/<section>/0..n-1, each <= 7168 bytes.
  # Cutting is by characters (Terraform's substr): 7168 per part for an ASCII payload, 1792 otherwise, so no part
  # exceeds 7168 bytes and no UTF-8 sequence is split. validation.tf checks both, and caps parts at 64.
  setting_sections = ["approvals", "cloud", "code_sources", "delivery", "gate", "github", "naming", "outbox", "repositories"]
  settings_value = merge(
    { for section in local.setting_sections : section => local.config[section] if contains(keys(local.config), section) },
    { naming = local.naming_section },
  )
  settings = { for section, value in local.settings_value : section => jsonencode(value) } # the payloads

  settings_sha256 = { for section, payload in local.settings : section => "sha256:${sha256(payload)}" }
  settings_bytes = {
    for section, payload in local.settings : section => (
      length(base64encode(payload)) / 4 * 3 - (endswith(base64encode(payload), "==") ? 2 : (endswith(base64encode(payload), "=") ? 1 : 0))
    )
  }
  settings_inline_index = {
    for section, value in local.settings_value : section => jsonencode({
      schema  = "settings-index-1.0"
      section = section
      commit  = var.setup_commit
      sha256  = local.settings_sha256[section]
      bytes   = local.settings_bytes[section]
      parts   = 0
      inline  = value
    })
  }
  settings_inline_fits = {
    for section, doc in local.settings_inline_index : section => (
      length(base64encode(doc)) / 4 * 3 - (endswith(base64encode(doc), "==") ? 2 : (endswith(base64encode(doc), "=") ? 1 : 0))
    ) <= 8192
  }
  settings_part_chars = {
    for section, payload in local.settings : section => local.settings_bytes[section] == length(payload) ? 7168 : 1792
  }
  settings_parts_count = {
    for section, payload in local.settings : section => local.settings_inline_fits[section] ? 0 : ceil(length(payload) / local.settings_part_chars[section])
  }
  settings_parts = merge({}, [
    for section, payload in local.settings : {
      for i in range(local.settings_parts_count[section]) : "${section}/${i}" => substr(payload, i * local.settings_part_chars[section], local.settings_part_chars[section])
    }
  ]...)
  settings_part_bytes = {
    for key, chunk in local.settings_parts : key => (
      length(base64encode(chunk)) / 4 * 3 - (endswith(base64encode(chunk), "==") ? 2 : (endswith(base64encode(chunk), "=") ? 1 : 0))
    )
  }
  settings_index = {
    for section, _ in local.settings : section => local.settings_inline_fits[section] ? local.settings_inline_index[section] : jsonencode({
      schema  = "settings-index-1.0"
      section = section
      commit  = var.setup_commit
      sha256  = local.settings_sha256[section]
      bytes   = local.settings_bytes[section]
      parts   = local.settings_parts_count[section]
    })
  }
  settings_names      = { for section, _ in local.settings : section => "${local.parameter_prefix}/settings/${section}" }
  settings_part_names = { for key, _ in local.settings_parts : key => "${local.parameter_prefix}/settings/${key}" }

  # Written by keygen, never by this module (ledger 02e section 10.2a, "keep the writers apart").
  evidence_public_key_name = "${local.parameter_prefix}/evidence/public-key"

  parameter_arn_prefix = "arn:aws:ssm:${local.region}:${local.account}:parameter/${local.namespace}"

  # -- the promoter's narrow role (Q-2; ledger 02e section 10.3) ------------------------------------------------
  role_match         = try(regex("^arn:aws:iam::([0-9]{12}):role/((?:[A-Za-z0-9+=,.@_-]+/)*)([A-Za-z0-9+=,.@_-]{1,64})$", tostring(local.cloud.workflow_role)), null)
  promoter_role_arn  = tostring(local.cloud.workflow_role)
  promoter_role_path = local.role_match == null ? "/" : "/${local.role_match[1]}"
  promoter_role_name = local.role_match == null ? "" : local.role_match[2]
  manage_role        = local.has_outbox && var.manage_promoter_role && !local.saas # SA-6: InitValue's pipeline in SaaS mode

  oidc_host         = "token.actions.githubusercontent.com"
  oidc_provider_arn = var.create_github_oidc_provider && !local.saas ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account}:oidc-provider/${local.oidc_host}"

  outbox_default_branch = !local.has_outbox ? null : coalesce(var.outbox_default_branch, "UNSET-outbox_default_branch")
  outbox_sub_repo       = !local.has_outbox ? null : coalesce(var.outbox_oidc_subject_repo, local.outbox_full)
  promoter_workflow_ref = local.has_outbox ? "${local.outbox_full}/.github/workflows/acse-promote.yml@refs/heads/${local.outbox_default_branch}" : null
  promoter_subject = !local.has_outbox ? null : (
    var.outbox_oidc_subject_includes_job_workflow_ref
    ? "repo:${local.outbox_sub_repo}:ref:refs/heads/${local.outbox_default_branch}:job_workflow_ref:${local.promoter_workflow_ref}"
    : "repo:${local.outbox_sub_repo}:ref:refs/heads/${local.outbox_default_branch}"
  )

  # Exactly the four store entries, nothing else in the namespace.
  promoter_parameter_arns = [
    "${local.parameter_arn_prefix}/settings/outbox",
    "${local.parameter_arn_prefix}/settings/naming",
    "${local.parameter_arn_prefix}/evidence/public-key",
  ]
  promoter_parameter_names = [
    "${local.parameter_prefix}/settings/outbox",
    "${local.parameter_prefix}/settings/naming",
    local.evidence_public_key_name,
  ]

  # -- generated files (spec 02e Amendments 2 and 3) ------------------------------------------------------------
  gate_payload = local.gate_config_enabled ? {
    gate_config_format_version = "1.0"
    tenant                     = local.tenant
    audience                   = local.gate_audience
    report_url                 = local.gate_report_url
  } : null

  # Where the promoter reads its App key: tenant.yaml's outbox.promoter_key (tenant-config-1.3), copied exactly into
  # the file, which is then promoter-config-1.1. Absent: the file stays promoter-config-1.0, member for member as
  # before, so a tenant that does not set it sees no change (the runtime's expected_config does the same).
  promoter_key_raw       = local.has_outbox ? try(local.config.outbox.promoter_key, null) : null
  promoter_key           = local.promoter_key_raw == null ? null : try({ for k, v in local.promoter_key_raw : tostring(k) => tostring(v) }, null)
  promoter_key_gcp       = try(local.promoter_key.store, null) == "gcp_secret_manager"
  promoter_config_schema = local.promoter_key == null ? "promoter-config-1.0" : "promoter-config-1.1"

  promoter_payload = local.has_outbox ? merge(
    {
      promoter_config_format_version = local.promoter_key == null ? "1.0" : "1.1"
      tenant                         = local.tenant
      cloud = {
        provider      = tostring(local.cloud.provider)
        region        = local.region
        workflow_role = local.promoter_role_arn
        namespace     = local.namespace
      }
    },
    { for k, v in { promoter_key = local.promoter_key } : k => v if v != null },
  ) : null

  policies_default_branch = !local.gate_config_enabled ? null : coalesce(var.policies_default_branch, try(data.github_repository.policies[0].default_branch, null), "main")

  generated_files = merge(
    local.gate_config_enabled ? {
      gate = {
        repository     = local.policies_name
        full_name      = tostring(local.repositories.policies)
        default_branch = local.policies_default_branch
        path           = ".github/acse-gate.json"
        schema         = "gate-config-1.0"
        template       = "${path.module}/templates/acse-gate.json.tftpl"
        payload_json   = jsonencode(local.gate_payload)
        branch_stem    = "setup-apply/acse-gate-config"
      }
    } : {},
    local.has_outbox ? {
      promoter = {
        repository     = local.outbox_name
        full_name      = local.outbox_full
        default_branch = local.outbox_default_branch
        path           = ".github/acse-promote.json"
        schema         = local.promoter_config_schema
        template       = "${path.module}/templates/acse-promote.json.tftpl"
        payload_json   = jsonencode(local.promoter_payload)
        branch_stem    = "setup-apply/acse-promote-config"
      }
    } : {},
  )
}
