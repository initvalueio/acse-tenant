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

variable "acse_gcp_web_identity_token_file" {
  description = "The workflow's GitHub OIDC token for audience acse-setup-gcp. Set by acse-setup-apply.yml 1.1.0 (TF_VAR_acse_gcp_web_identity_token_file)."
  type        = string
  default     = null
}

variable "use_web_identity" {
  description = "Sign in to Google Cloud with the workflow's OIDC token (true, in acse-setup-apply.yml). false only for the one bootstrap apply a project owner runs with their own credentials; that apply also skips publishing."
  type        = bool
  default     = true
}

variable "saas_publish_role_arn" {
  description = "The publish role InitValue created for your tenant, from the Access page (SA-3). Not secret."
  type        = string
}

variable "gcp_project_id" {
  description = "Your Google Cloud project that holds the keys and the workload identity pool."
  type        = string
}

variable "gcp_workload_identity_provider" {
  description = "//iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/acse-setup/providers/github: the gcp_setup_credential module's workload_identity_provider output, after the bootstrap apply."
  type        = string
}

variable "setup_app" {
  description = "Your own setup GitHub App, not ACSE Read or ACSE Change: organization administration write (rulesets); contents and pull requests write on the policies repository; administration write on the setup repository (environment, OIDC subject template). Its key is in a Secret Manager secret in gcp_project_id that only the apply job can read."
  type = object({
    id                    = number
    installation_id       = number
    private_key_secret_id = string
  })
}

variable "plan_app" {
  description = "Your read-only GitHub App for the post-merge plan (administration, contents, pull requests and metadata read, organization administration read; no write). Its key is in its own Secret Manager secret that only the plan job can read."
  type = object({
    id                    = number
    installation_id       = number
    private_key_secret_id = string
  })

  validation {
    condition     = var.plan_app.private_key_secret_id != var.setup_app.private_key_secret_id
    error_message = "The read-only App's key must not be the setup App's key."
  }
}

variable "acse_app_keys" {
  description = "The ACSE Read and ACSE Change App keys, in Secret Manager secrets only the apply job can read. Change version (any label, for example a date) when you rotate either key: the next apply puts both into InitValue's namespace. Null version: they are never put."
  type = object({
    read_secret_id   = string
    change_secret_id = string
    version          = optional(string)
  })
}

variable "default_branches" {
  description = "Default branches of the setup and policies repositories. Required: the pull request's plan has no GitHub credential to look them up."
  type = object({
    setup    = string
    policies = string
  })
}

variable "setup_oidc_subject_repo" {
  description = "The setup repository's OIDC sub repo segment: owner/name, or owner@<id>/name@<id> on GitHub's immutable subject format. Null: owner/name."
  type        = string
  default     = null
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
