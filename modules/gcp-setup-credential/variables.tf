variable "gcp_setup_project" {
  description = "The project id of your DEDICATED setup project: it holds this pool, the setup and plan App keys, the ACSE App keys (SaaS) and the promoter key (Outbox), and nothing else. The apply job gets roles/editor and roles/iam.securityAdmin on this project only."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_setup_project))
    error_message = "gcp_setup_project must be a Google Cloud project id."
  }
}

variable "gcp_setup_project_is_dedicated" {
  description = "You confirm that gcp_setup_project holds nothing but what this module lists. Terraform cannot check it; the plan refuses until it is true."
  type        = bool
  default     = false
}

variable "setup_repository" {
  description = "repositories.setup from tenant.yaml (owner/name): the only repository whose tokens the provider accepts."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$", var.setup_repository))
    error_message = "setup_repository must be owner/name."
  }
}

variable "setup_oidc_subjects" {
  description = "The acse-tenant module's setup_oidc_subjects output: {apply, plan, check}."
  type = object({
    apply = string
    plan  = string
    check = string
  })
}

variable "setup_credential_secret_id" {
  description = "Secret Manager secret id (name or projects/<p>/secrets/<name>) of the setup App's private key: organization administration write. Only the apply job can read it."
  type        = string
}

variable "setup_plan_credential_secret_id" {
  description = "Secret Manager secret id of the read-only App's private key. Only the post-merge plan job can read it."
  type        = string
}

variable "app_key_secret_ids" {
  description = "SaaS mode: Secret Manager secret ids of the ACSE Read and ACSE Change App keys, which the apply job puts into InitValue's namespace. Only the apply job can read them."
  type        = list(string)
  default     = []
}

variable "pool_id" {
  description = "Workload identity pool id."
  type        = string
  default     = "acse-setup"
}

variable "provider_id" {
  description = "Workload identity pool provider id."
  type        = string
  default     = "github"
}

variable "audience" {
  description = "The audience acse-setup-apply.yml requests for its GCP token (template 1.1.0 and later). Keep the default."
  type        = string
  default     = "acse-setup-gcp"
}

variable "plan_project_roles" {
  description = "Project roles for the post-merge plan job: broad read, including IAM policies."
  type        = list(string)
  default     = ["roles/viewer", "roles/iam.securityReviewer"]
}

variable "check_project_roles" {
  description = "Project roles for the pull request's check job: broad read. It reads no secret."
  type        = list(string)
  default     = ["roles/viewer", "roles/iam.securityReviewer"]
}

variable "promoter" {
  description = "Outbox tenants: the acse-tenant module's promoter_oidc output (repository, subject, job_workflow_ref) plus secret_id, the promoter App key's Secret Manager secret in this project. acse-promote.yml gets its own provider and principal, which read exactly that secret and nothing else. Null: no promoter."
  type = object({
    repository       = string
    subject          = string
    job_workflow_ref = string
    secret_id        = string
  })
  default = null
}

variable "promoter_provider_id" {
  description = "Workload identity pool provider id for acse-promote.yml."
  type        = string
  default     = "github-promoter"
}

variable "promoter_audience" {
  description = "The audience acse-promote.yml requests for its GCP token. Promoter template 1.1.0 (core) must use the same value."
  type        = string
  default     = "acse-promote-gcp"
}
