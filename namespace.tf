# Spec 02e section 3: the namespace acse/<tenant>/ in the customer's own account.
#
# Secrets: containers only. Spec 02b D-3 asks for a {"status":"empty"} placeholder; this module writes no version at
# all, because a Terraform-managed secret version is refreshed by reading its value (GetSecretValue), so every plan
# would read the App keys once the customer puts them in. A secret with no version is what the runtime reports as
# missing, which is what the placeholder means. See docs/decisions.md (DEC-3).
#
# Settings (T-5; DEC-6, the Architecture Owner 2026-11-07): settings/<section> is always a settings-index-1.0 document, with the
# section inline when it fits and in settings/<section>/0..n-1 otherwise. Every parameter is Advanced tier (8 KB).
# The parts are written first and the index last (depends_on), so a reader that checks the index's sha256 after
# reassembling never accepts a mix; parts left over from a longer earlier version are destroyed after the index is
# updated, because Terraform destroys a dependency only after its dependents change. Only this module writes
# settings/*; it never writes evidence/public-key, which keygen owns (ledger 02e section 10.2a).

resource "aws_secretsmanager_secret" "namespace" {
  for_each = local.secret_paths

  name                    = local.secret_names[each.key]
  description             = each.value
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_in_days
  tags                    = merge(var.tags, { "acse:tenant" = local.tenant, "acse:path" = each.key })

  depends_on = [terraform_data.tenant_config]
}

resource "aws_ssm_parameter" "settings_part" {
  for_each = local.settings_parts

  name           = local.settings_part_names[each.key]
  description    = "ACSE settings: part ${split("/", each.key)[1]} of the ${split("/", each.key)[0]} section of config/tenant.yaml. Read it only through settings/${split("/", each.key)[0]} (settings-index-1.0)."
  type           = "String"
  data_type      = "text"
  tier           = "Advanced"
  insecure_value = each.value
  tags           = merge(var.tags, { "acse:tenant" = local.tenant, "acse:path" = "settings/${each.key}" })

  depends_on = [terraform_data.tenant_config]
}

resource "aws_ssm_parameter" "settings" {
  for_each = local.settings_index

  name           = local.settings_names[each.key]
  description    = "ACSE settings: the index (settings-index-1.0) of the ${each.key} section of config/tenant.yaml, published by the setup apply. Do not edit: the next apply overwrites it, and the runtime's daily drift check compares it with the merged file."
  type           = "String"
  data_type      = "text"
  tier           = "Advanced"
  insecure_value = each.value
  tags           = merge(var.tags, { "acse:tenant" = local.tenant, "acse:path" = "settings/${each.key}" })

  # Parts first, index last.
  depends_on = [terraform_data.tenant_config, aws_ssm_parameter.settings_part]
}
