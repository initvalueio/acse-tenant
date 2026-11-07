# Inputs. The one that matters is tenant_yaml: everything ACSE-specific comes from the merged config/tenant.yaml
# (spec 02e T-2). The others say how this module meets the customer's own GitHub organization and AWS account.

variable "tenant_yaml" {
  description = "The text of config/tenant.yaml (tenant-config-1.0, 1.1 or 1.2), exactly as committed: pass file(\"$${path.root}/../config/tenant.yaml\"). The module parses it, validates what it depends on, and hashes these exact bytes for generated_from.tenant_yaml_sha256."
  type        = string
  nullable    = false

  validation {
    condition     = can(yamldecode(var.tenant_yaml).tenant)
    error_message = "tenant_yaml is not a YAML mapping with a tenant member. Pass the text of config/tenant.yaml."
  }
}

variable "setup_commit" {
  description = "The setup repository commit this tenant.yaml was read at (40 or 64 hex): the workflow passes github.sha. Recorded as generated_from.commit in the generated files, and only when their content changes."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-f]{40}([0-9a-f]{24})?$", var.setup_commit))
    error_message = "setup_commit must be a 40- or 64-hex commit id (github.sha)."
  }
}

# -- AWS: the namespace and the promoter's role --------------------------------------------------------------------

variable "kms_key_arn" {
  description = "A customer-managed KMS key for the namespace's secrets. Null: the AWS-managed aws/secretsmanager key. When set, the promoter role gains kms:Decrypt on it through Secrets Manager only."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias."
  }
}

variable "secret_recovery_window_in_days" {
  description = "Recovery window for a namespace secret this module stops managing (for example when the outbox is removed). 0 deletes at once; 7 to 30 can be restored."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_in_days == 0 || (var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30)
    error_message = "secret_recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the account's IAM OIDC provider for token.actions.githubusercontent.com. Off by default: acse-setup-apply.yml itself federates through that provider, so it normally exists before this module first runs, and an account holds at most one per URL. When false, its ARN is derived from cloud.account. Set true when the first apply runs with other credentials in an account that has none."
  type        = bool
  default     = false
}

variable "manage_promoter_role" {
  description = "Create cloud.workflow_role, the promoter's narrow role (Outbox tenants only). Set false only where another root already manages that exact role with the same trust and grants (ACSE's own dev environment, lane LI-2)."
  type        = bool
  default     = true
}

variable "outbox_oidc_subject_includes_job_workflow_ref" {
  description = "Recommended by ledger 02e section 10.3, not required: set the outbox repository's OIDC subject template to repo + context + job_workflow_ref, so the role trusts only .github/workflows/acse-promote.yml on the default branch rather than any workflow there. Off by default because it is not verified that every GitHub plan offers subject customisation (ledger 02e section 10.10)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for every AWS resource this module creates."
  type        = map(string)
  default     = {}
}

# -- GitHub: rulesets and generated files --------------------------------------------------------------------------

variable "ruleset_enforcement" {
  description = "Enforcement of the two organization rulesets. Spec 02b section 4 layer 3: ship in evaluate, review what GitHub reports it would block, then switch to active. Readiness passes only when active. evaluate needs GitHub Enterprise Cloud; on other plans use active."
  type        = string
  default     = "evaluate"

  validation {
    condition     = contains(["evaluate", "active", "disabled"], var.ruleset_enforcement)
    error_message = "ruleset_enforcement must be evaluate, active or disabled."
  }
}

variable "ruleset_repository_include" {
  description = "Repository name patterns the organization rulesets cover. ~ALL is every repository (the 02b template)."
  type        = list(string)
  default     = ["~ALL"]
}

variable "ruleset_repository_exclude" {
  description = "Repository name patterns the organization rulesets leave out. An excluded repository is not Direct-ready (layer 3 fails there) and falls back to Outbox or patches."
  type        = list(string)
  default     = []
}

variable "ruleset_bypass_integration_ids" {
  description = "GitHub App ids of the customer's own bots that push branches or tags (Dependabot, Renovate, their CI App, and the App this setup apply uses when generated_files_mode is pull_request). They bypass both rulesets. ACSE Change's id is refused here: keeping it off the bypass list is what keeps it inside the boundary."
  type        = list(number)
  default     = []
}

variable "ruleset_bypass_deploy_keys" {
  description = "Let deploy keys bypass both rulesets (02b Amendment 3 item 4 names deploy keys in the bypass guidance). Set false if nothing in the organization pushes with a deploy key."
  type        = bool
  default     = true
}

variable "generated_files_mode" {
  description = "How .github/acse-gate.json and .github/acse-promote.json reach their repositories' default branches. pull_request (default): when the default branch's copy differs from the one generated from tenant.yaml (generated_from excluded), open a branch and a pull request for the customer to merge; nothing is written when they already match. direct: commit to the default branch, which needs the credential to be allowed past that branch's protection."
  type        = string
  default     = "pull_request"

  validation {
    condition     = contains(["pull_request", "direct"], var.generated_files_mode)
    error_message = "generated_files_mode must be pull_request or direct."
  }
}

variable "policies_default_branch" {
  description = "The policies repository's default branch. Null: read from GitHub."
  type        = string
  default     = null
}

variable "outbox_default_branch" {
  description = "The outbox repository's default branch. Required for Outbox tenants: the promoter role trusts this branch only, and the pull request's cloud-only plan has no GitHub credential to look it up (SC-5)."
  type        = string
  default     = null
}

variable "commit_author" {
  description = "Optional author name and email for commits of the generated files. Null: GitHub attributes the commit to the credential."
  type = object({
    name  = string
    email = string
  })
  default = null
}

variable "warn_unseen_gate_repositories" {
  description = "Spec 02e Amendment 3 item 5 (GA-4, GA-26): during plan, warn (never fail) when a gate.registered_repositories entry is not visible to ACSE Read. Reads the organization's App installations, which needs organization administration read on the credential; if that read fails the plan still succeeds, with a warning."
  type        = bool
  default     = true
}

# -- The setup apply's own identities (DEC-20, the Architecture Owner 2026-11-07) ---------------------------------------------------

variable "setup_credential_secret_arn" {
  description = "ARN of the Secrets Manager secret, named by you and outside acse/<tenant>/, that holds your setup GitHub App's private key (organization administration write). The module never reads it: it attaches a resource policy so that only the setup apply role (and setup_credential_extra_reader_arns) can read it. Null: no setup roles are created or wired."
  type        = string
  default     = null

  validation {
    condition     = var.setup_credential_secret_arn == null || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.setup_credential_secret_arn))
    error_message = "setup_credential_secret_arn must be a Secrets Manager secret ARN."
  }
}

variable "setup_plan_credential_secret_arn" {
  description = "ARN of the secret, named by you and outside acse/<tenant>/, that holds your read-only GitHub App's key (administration, contents, pull requests and metadata read; no write). Required with setup_credential_secret_arn. Only the post-merge plan role can read it: its resource policy denies everyone else (third round, \"Read-only post-merge plan job\")."
  type        = string
  default     = null

  validation {
    condition     = var.setup_plan_credential_secret_arn == null || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.setup_plan_credential_secret_arn))
    error_message = "setup_plan_credential_secret_arn must be a Secrets Manager secret ARN."
  }
}

variable "setup_credential_extra_reader_arns" {
  description = "IAM role ARNs besides the setup apply role that may read the setup credential (for example a break-glass administrator role used for the first, bootstrap apply). Never an ACSE role."
  type        = list(string)
  default     = []
}

variable "setup_apply_role_name" {
  description = "Name of the role acse-setup-apply.yml's apply job assumes. The only role that can read the setup credential."
  type        = string
  default     = "acse-setup-apply"
}

variable "setup_plan_role_name" {
  description = "Name of the role the post-merge plan job assumes: default branch, no approval gate, reads only the read-only App's key."
  type        = string
  default     = "acse-setup-plan"
}

variable "setup_plan_policy_arns" {
  description = "Managed policies for the post-merge plan role: broad read."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

variable "setup_check_role_name" {
  description = "Name of the role the pull request's plan job assumes (the cloud side only, SC-5). It cannot read the setup credential and holds no GitHub credential."
  type        = string
  default     = "acse-setup-check"
}

variable "setup_apply_policy_arns" {
  description = "Managed policies for the setup apply role. Broad by design (it runs this module and your own root): no service-level lists."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

variable "setup_check_policy_arns" {
  description = "Managed policies for the PR-check role: broad read. ReadOnlyAccess does not grant secretsmanager:GetSecretValue, and the setup credential's resource policy denies it to this role regardless."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

variable "setup_default_branch" {
  description = "The setup repository's default branch. Required when setup_credential_secret_arn is set: the apply role's trust and the apply environment name it, and the pull request's cloud-only plan has no GitHub credential to look it up (SC-5)."
  type        = string
  default     = null
}

variable "setup_oidc_subject_repo" {
  description = "The repo segment of the setup repository's OIDC sub, without \"repo:\": owner/name, or owner@<owner id>/name@<repository id> under GitHub's immutable subject format, which repositories created after 2026-07-15 use by default. Null: owner/name. Read it from GET /repos/{owner}/{repo}/actions/oidc/customization/sub (sub_claim_prefix); the apply plan warns when they differ (DEC-29)."
  type        = string
  default     = null

  validation {
    condition     = var.setup_oidc_subject_repo == null || can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}(@[0-9]+)?/[A-Za-z0-9._-]{1,100}(@[0-9]+)?$", var.setup_oidc_subject_repo))
    error_message = "setup_oidc_subject_repo must be owner/name or owner@<id>/name@<id>."
  }
}

variable "outbox_oidc_subject_repo" {
  description = "The same for the outbox repository, used in the promoter role's trust. Null: owner/name (DEC-29)."
  type        = string
  default     = null

  validation {
    condition     = var.outbox_oidc_subject_repo == null || can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}(@[0-9]+)?/[A-Za-z0-9._-]{1,100}(@[0-9]+)?$", var.outbox_oidc_subject_repo))
    error_message = "outbox_oidc_subject_repo must be owner/name or owner@<id>/name@<id>."
  }
}

variable "setup_apply_environment" {
  description = "The GitHub environment the apply job runs in. The apply role trusts only this environment; the module creates it in the setup repository, deployable from the default branch only, with no administrator bypass, self-review prevented and setup_apply_environment_reviewers required. Keep the default: the template names it."
  type        = string
  default     = "acse-setup-apply"
}

variable "setup_apply_environment_reviewers" {
  description = "Required reviewers for the apply environment: GitHub user ids and team ids, at least one in all (SC-1). Self-review is prevented, so the person who merged cannot approve their own apply."
  type = object({
    users = list(number)
    teams = list(number)
  })
  default = { users = [], teams = [] }
}

variable "runtime_role_arn" {
  description = "Optional: the ACSE runtime's role ARN, only so the module can refuse a setup role that is the same role."
  type        = string
  default     = null
}
