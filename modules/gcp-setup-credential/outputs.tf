output "workload_identity_provider" {
  description = "The provider's full name, //iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>: the audience of the external_account credential your root's google provider uses."
  value       = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.github.name}"
}

output "principals" {
  description = "Job => the federated principal set granted here."
  value       = local.principal
}

output "acse_job_mapping" {
  description = "The CEL expression that maps a token's sub to apply, plan, check or none."
  value       = local.acse_job_expression
}
