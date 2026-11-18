# Production-tenant identities trusted by HCP Terraform / Terraform Enterprise dynamic provider credentials.
#
# The pipelines/terraform/modules/purview-config module runs the PPDF CLI from Terraform:
#   - plan phase  -> reader identity   (subject ...:run_phase:plan)
#   - apply phase -> deployer identities (subject ...:run_phase:apply), only after a human confirms the run
#                    (workspace setting "Manual apply"; restrict "Apply runs" permission to the approver team).
# The engine reads the workload identity token from TFC_WORKLOAD_IDENTITY_TOKEN, which HCP Terraform injects when
# the workspace variable TFC_WORKLOAD_IDENTITY_AUDIENCE = api://AzureADTokenExchange is set (environment variable).
# The token's subject carries the run phase, so the same workspace token is accepted by the reader during plan and
# by the deployer only during apply. Use one workspace per workload so a workspace can never mint another
# workload's deployer token.
# Self-hosted TFC agents in Azure can instead use a user-assigned managed identity (see the azure-devops example).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azuread = { source = "hashicorp/azuread", version = ">= 3.0.0, < 4.0.0" }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

variable "tenant_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000"
}

variable "tfc_organization" {
  type    = string
  default = "contoso"
}

variable "tfc_project" {
  type    = string
  default = "purview"
}

variable "workspaces" {
  description = "One workspace per workload keeps each deployer token isolated. Map of role => workspace name."
  type        = map(string)
  default = {
    dlp        = "purview-prod-dlp"
    retention  = "purview-prod-retention"
    classifier = "purview-prod-classifiers"
    rbac       = "purview-prod-rbac"
  }
}

locals {
  reader_fic = [
    for r, ws in var.workspaces : {
      role             = "reader"
      name             = "tfc-${ws}-plan"
      type             = "terraform-cloud"
      tfc_organization = var.tfc_organization
      tfc_project      = var.tfc_project
      tfc_workspace    = ws
      tfc_run_phase    = "plan"
    }
  ]
  deployer_fic = [
    for r, ws in var.workspaces : {
      role             = r
      name             = "tfc-${ws}-apply"
      type             = "terraform-cloud"
      tfc_organization = var.tfc_organization
      tfc_project      = var.tfc_project
      tfc_workspace    = ws
      tfc_run_phase    = "apply"
    }
  ]
}

module "ppdf_identities" {
  source                = "../../modules/ppdf-identities"
  name_prefix           = "ppdf-prod"
  tenant_id             = var.tenant_id
  federated_credentials = concat(local.reader_fic, local.deployer_fic)
}

output "environment_identities" { value = module.ppdf_identities.environment_identities }
output "grant_input" { value = module.ppdf_identities.grant_input }
output "approver_group_ids" { value = module.ppdf_identities.approver_group_ids }
output "next_steps" { value = module.ppdf_identities.next_steps }
