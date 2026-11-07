variable "project_id" {
  description = "Your Google Cloud project that holds the setup secrets and the workload identity pool."
  type        = string
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

variable "apply_project_roles" {
  description = "Project roles for the apply job, so it can maintain this module's pool, provider and grants on later applies. Broad by design, as the AWS apply role's AdministratorAccess: no service-level lists."
  type        = list(string)
  default     = ["roles/editor", "roles/iam.securityAdmin"]
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
