variable "acse_setup_phase" {
  description = "check (pull request), plan (post-merge, read-only) or apply. Set by acse-setup-apply.yml (TF_VAR_acse_setup_phase)."
  type        = string
  default     = "apply"

  validation {
    condition     = contains(["check", "plan", "apply"], var.acse_setup_phase)
    error_message = "acse_setup_phase must be check, plan or apply."
  }
}

variable "setup_commit" {
  description = "The commit being planned or applied. Set by acse-setup-apply.yml (TF_VAR_setup_commit = github.sha)."
  type        = string
}

variable "use_web_identity" {
  description = "Sign in to AWS with the workflow's OIDC token (true, in acse-setup-apply.yml). false only for the one bootstrap apply an administrator runs with their own credentials."
  type        = bool
  default     = true
}

variable "setup_apply_role_name" {
  description = "Must match the module's setup_apply_role_name."
  type        = string
  default     = "acse-setup-apply"
}

variable "setup_plan_role_name" {
  description = "Must match the module's setup_plan_role_name."
  type        = string
  default     = "acse-setup-plan"
}

variable "setup_check_role_name" {
  description = "Must match the module's setup_check_role_name."
  type        = string
  default     = "acse-setup-check"
}

variable "setup_app" {
  description = "Your own setup GitHub App, not ACSE Read or ACSE Change: organization administration write (rulesets); contents and pull requests write on the policies and outbox repositories; administration write on the setup and outbox repositories (environment, OIDC subject templates). Its key sits in a Secrets Manager secret you name, outside acse/<tenant>/. Only the apply phase uses it; the post-merge plan uses plan_app, and pull requests get no GitHub credential (SC-5)."
  type = object({
    id                     = number
    installation_id        = number
    private_key_secret_arn = string
  })
}

variable "plan_app" {
  description = "Your read-only GitHub App for the post-merge plan: repository administration, contents, pull requests and metadata read, plus organization administration read (organization rulesets and App installations); no write. Its key sits in its own Secrets Manager secret you name, outside acse/<tenant>/; only acse-setup-plan can read it."
  type = object({
    id                     = number
    installation_id        = number
    private_key_secret_arn = string
  })

  validation {
    condition     = var.plan_app.private_key_secret_arn != var.setup_app.private_key_secret_arn
    error_message = "The read-only App's key must not be the setup App's key."
  }
}

variable "default_branches" {
  description = "Default branches of the setup, policies and outbox repositories. Required: the pull request's plan has no GitHub credential to look them up."
  type = object({
    setup    = string
    policies = string
    outbox   = optional(string)
  })
}

variable "oidc_subject_repo" {
  description = "The repo segment of each repository's OIDC sub, without \"repo:\": owner/name, or owner@<id>/name@<id> for repositories on GitHub's immutable subject format (created after 2026-07-15, or opted in). Read sub_claim_prefix from GET /repos/{owner}/{repo}/actions/oidc/customization/sub. Null: owner/name."
  type = object({
    setup  = optional(string)
    outbox = optional(string)
  })
  default = {}
}

variable "bootstrap_admin_role_arns" {
  description = "Administrator roles that may also read the setup App's key (for the bootstrap apply and break-glass). Never an ACSE role."
  type        = list(string)
  default     = []
}

variable "apply_environment_reviewers" {
  description = "GitHub user and team ids required to approve each apply: at least one (SC-1). Self-review is prevented."
  type = object({
    users = list(number)
    teams = list(number)
  })
  default = { users = [], teams = [] }
}

variable "other_bot_app_ids" {
  description = "Your other bots that push branches or tags (Dependabot, Renovate, CI Apps). Never ACSE Change."
  type        = list(number)
  default     = []
}

variable "ruleset_enforcement" {
  description = "evaluate first, then active after review (spec 02b section 4 layer 3)."
  type        = string
  default     = "evaluate"
}

variable "optional_permissions" {
  description = "Opt-in reads ACSE's setup never requests, per cloud (empty by default). Each unlocks named checks; see terraform.tfvars.example."
  type = object({
    aws   = optional(list(string), [])
    gcp   = optional(list(string), [])
    azure = optional(list(string), [])
  })
  default = {}
}
