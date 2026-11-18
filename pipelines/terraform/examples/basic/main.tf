# One HCP Terraform workspace per workload (here: purview-prod-dlp), matching
# identities/terraform/examples/terraform-cloud. Create one copy of this root module (or one workspace using it with a
# different var.workload) for dlp, retention, classifier and rbac.
#
# Workspace settings:
#   - Execution mode: Remote (or Agent). The run image needs PowerShell 7.4+ (custom agent image, or install pwsh
#     in a pre-plan run task); the hosted runner image does not ship pwsh.
#   - Apply method: Manual apply. Grant "Apply runs" only to the approver team for this workload/tier.
#   - Environment variable: TFC_WORKLOAD_IDENTITY_AUDIENCE = api://AzureADTokenExchange
#     (HCP Terraform then injects TFC_WORKLOAD_IDENTITY_TOKEN, which PPDF uses to sign in).
#
# Repository layout this example assumes:
#   ./ppdf    framework checkout pinned to a release (git submodule or a VCS-driven workspace with both repos)
#   ./config  your configuration (environments/, artifacts/)

terraform {
  required_version = ">= 1.6.0"
  cloud {
    organization = "contoso"
    workspaces { name = "purview-prod-dlp" }
  }
}

variable "workload" {
  type    = string
  default = "dlp"
}

variable "approved_tier" {
  description = "Highest tier this workspace may apply. Raising it is a reviewed change to this variable."
  type        = string
  default     = "elevated"
}

module "purview" {
  source = "./ppdf/pipelines/terraform/modules/purview-config"

  framework_path = "${path.root}/ppdf"
  config_root    = "${path.root}/config"
  environment    = "prod"
  command        = "plan"
  stage          = "auto"
  workloads      = [var.workload]
  approved_tier  = var.approved_tier
}

output "ppdf_plan" {
  value = {
    hash          = module.purview.plan_hash
    has_changes   = module.purview.has_changes
    approval_tier = module.purview.approval_tier
    workloads     = module.purview.workloads
    summary       = module.purview.summary
  }
}

output "ppdf_plan_markdown" {
  value = module.purview.plan_markdown
}
