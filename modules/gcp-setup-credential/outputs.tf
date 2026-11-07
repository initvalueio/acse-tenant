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

output "promoter_workload_identity_provider" {
  description = "The promoter's provider full name, //iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<promoter provider>: the external_account audience acse-promote.yml (promoter template 1.1.0) exchanges its token at. Null without a promoter."
  value       = var.promoter == null ? null : "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.promoter[0].name}"
}

output "promoter_key_secret_name" {
  description = "The promoter App key's secret resource name, projects/<project>/secrets/<name>. acse-promote.yml reads its latest version; nothing else can. Null without a promoter."
  value       = var.promoter == null ? null : "projects/${local.project}/secrets/${local.short[var.promoter.secret_id]}"
}

output "promoter_audience" {
  description = "The audience the promoter's token must carry. Null without a promoter."
  value       = var.promoter == null ? null : var.promoter_audience
}
