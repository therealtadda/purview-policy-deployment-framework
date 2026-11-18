# Production-tenant identities trusted by GitHub Actions through OIDC (workload identity federation).
#
# Trust model:
#   - reader     -> GitHub environment "<prefix>-read"   (plan, simulation-report, drift; no reviewers needed)
#   - deployers  -> GitHub environments "<prefix>-<tier>" (low|standard|elevated|critical), each protected by
#                   required reviewers. The plan selects the environment (approval_environment output), so a
#                   deployer token can only be minted after the human gate for that tier has been passed.
# The subject is repo:<org>/<repo>:environment:<name>; tokens from branches/PRs without that environment are rejected.

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

variable "github_repository" {
  type    = string
  default = "contoso/purview-config"
}

variable "approval_prefix" {
  description = "Must match approvals.pattern in the environment file (prod and ring-pilot both use prod-{tier})."
  type        = string
  default     = "prod"
}

locals {
  tiers     = ["low", "standard", "elevated", "critical"]
  deployers = ["dlp", "retention", "classifier", "rbac"]

  reader_fic = [{
    role               = "reader"
    name               = "github-${var.approval_prefix}-read"
    type               = "github"
    github_repository  = var.github_repository
    github_environment = "${var.approval_prefix}-read"
  }]

  deployer_fic = flatten([
    for r in local.deployers : [
      for t in local.tiers : {
        role               = r
        name               = "github-${var.approval_prefix}-${t}"
        type               = "github"
        github_repository  = var.github_repository
        github_environment = "${var.approval_prefix}-${t}"
      }
    ]
  ])
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
