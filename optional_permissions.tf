# Optional permissions: the reads ACSE's checks can use that ACSE's setup never requests (the provider packs'
# GATED_PERMISSIONS in cio-acse-core). Without one, its checks read "Not judged: needs permission X (not requested by
# setup)"; nothing else changes. Opt-in only: the default is empty for every cloud, and nothing here changes the
# default grants.
#
# Koushik, 2026-11-13: "if need arises for more permissions we will let the client know and seek additional
# permissions. Any way we are creating a acse-setup repo, probably lets add the additional permissions here as a tfvars
# file and ask the client to run a Gh pipeline, and this is the same practice we adopt for GCP, AWS and Azure".
#
# AWS: the listed actions are granted as one inline policy on the scanner role in this module's AWS account
# (aws_scanner_role_name, default ACSEReadOnlyScanner). GCP and Azure: validated and reported (output
# optional_permissions) but not granted here, because this module holds no Google or Azure provider (OD-16); the grant
# for those clouds is an open decision (docs/decisions.md DEC-49).

variable "optional_permissions" {
  description = "Opt-in permissions beyond ACSE's default setup, per cloud: aws (IAM actions), gcp (IAM permissions), azure (Graph application permissions or RBAC actions). Each must be one of local.optional_permission_catalogue's, which also names the checks it unlocks. Empty (the default) grants nothing more."
  type = object({
    aws   = optional(list(string), [])
    gcp   = optional(list(string), [])
    azure = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for cloud, wanted in var.optional_permissions : alltrue([
        for permission in wanted : contains(keys(local.optional_permission_catalogue[cloud]), permission)
      ])
    ])
    error_message = "optional_permissions names a permission ACSE does not use. Each must be listed in the module's optional_permission_catalogue for its cloud."
  }
}

variable "aws_scanner_role_name" {
  description = "Name of ACSE's scanner role in this AWS account (the cloud connection's setup creates it). The AWS optional permissions are attached to it as one inline policy, only when optional_permissions.aws is not empty."
  type        = string
  default     = "ACSEReadOnlyScanner"
}

locals {
  # Every gated permission of the provider packs, with the checks it unlocks (cio-acse-core: provider-packs/aws,
  # gcp and acse_azure, checks/collect.py GATED_PERMISSIONS whose granted_by_setup is false). A permission setup
  # already grants is not optional and is not listed.
  optional_permission_catalogue = {
    aws = {
      "macie2:GetMacieSession" = ["aws-macie-enabled"]
    }
    gcp = {
      "policyanalyzer.serviceAccountKeyLastAuthenticationActivities.query" = ["gcp-iam-sa-key-unused"]
    }
    azure = {
      "Graph:AuditLog.Read.All"                           = ["azure-entra-vm-access-users-mfa", "azure-entra-users-mfa"]
      "Graph:RoleManagement.Read.Directory"               = []
      "Microsoft.Authorization/roleAssignments/read at /" = ["azure-rbac-user-access-admin-restricted"]
    }
  }

  optional_aws_actions = sort(distinct(var.optional_permissions.aws))
}

resource "aws_iam_role_policy" "optional_reads" {
  count = length(local.optional_aws_actions) > 0 ? 1 : 0

  name = "acse-optional-reads"
  role = var.aws_scanner_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AcseOptionalReads"
      Effect   = "Allow"
      Action   = local.optional_aws_actions
      Resource = "*"
    }]
  })
}

output "optional_permissions" {
  description = "Per cloud, each optional permission opted into, the checks it unlocks, and whether this module granted it (AWS) or only recorded it (GCP, Azure: DEC-49)."
  value = {
    for cloud, wanted in var.optional_permissions : cloud => {
      for permission in distinct(wanted) : permission => {
        checks  = local.optional_permission_catalogue[cloud][permission]
        granted = cloud == "aws"
      }
    }
  }
}
