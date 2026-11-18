output "plan_hash" {
  description = "SHA-256 of the PPDF plan document that this Terraform plan will apply."
  value       = data.external.ppdf.result.plan_hash
}

output "has_changes" {
  value = local.has_changes
}

output "approval_tier" {
  description = "Approval tier the PPDF plan requires (low, standard, elevated, critical)."
  value       = data.external.ppdf.result.approval_tier
}

output "approval_environment" {
  value = data.external.ppdf.result.approval_environment
}

output "workloads" {
  description = "Workloads with pending changes."
  value       = data.external.ppdf.result.workloads
}

output "summary" {
  description = "Action counts (create, update, adopt, delete, noop, blocked, deferred)."
  value       = jsondecode(data.external.ppdf.result.summary)
}

output "plan_markdown" {
  description = "Human-readable PPDF plan; reviewers should read this before confirming the run."
  value       = data.external.ppdf.result.plan_markdown
}
