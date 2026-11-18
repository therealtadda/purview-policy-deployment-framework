# Production-tenant identities trusted by Azure DevOps through workload identity federation service connections.
#
# One service connection per identity (sc-ppdf-prod-reader, sc-ppdf-prod-dlp, ...). Each service connection is
# restricted in Azure DevOps (Project settings > Service connections > Security / Approvals and checks) so that:
#   - only the PPDF pipeline is authorised to use it, and
#   - deployer connections carry an "Approvals" check (approver group) and "Business hours" / "Exclusive lock" checks.
# Issuer: new WIF service connections use the Microsoft Entra issuer (https://login.microsoftonline.com/<tenant>/v2.0)
# and Azure DevOps generates the subject. Workflow:
#   1. terraform apply with ado_subjects = {} for deployers you are not ready to federate yet (the app is still created),
#   2. create each service connection as "App registration (manual) > Workload identity federation", keep it as a draft,
#      copy its Subject identifier into ado_subjects[<role>], terraform apply, then "Verify and save" in ADO.
# Set ado_issuer_mode = "legacy" only for existing connections still on vstoken.dev.azure.com
# (deprecated; Azure DevOps retires that issuer on 2027-07-01).
# The pipeline templates (pipelines/azure-devops) run each identity in its own AzureCLI@2 step that references its
# service connection, because Azure DevOps refuses OIDC token requests for connections the job does not reference.
# spec.identities.<role>.adoServiceConnectionId is only needed for custom pipelines that request tokens directly
# (SYSTEM_OIDCREQUESTURI) and must still reference that connection in the same job.
#
# This example also shows the managed-identity alternative for self-hosted agents (Azure VM scale set agents):
# set use_self_hosted_mi = true and the deployers trust a user-assigned managed identity instead of ADO OIDC.

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

variable "ado_organization" {
  type    = string
  default = "contoso"
}

variable "ado_organization_id" {
  description = "Azure DevOps organisation GUID (Organization settings > Microsoft Entra, or the issuer shown on the service connection)."
  type        = string
  default     = "00000000-0000-0000-0000-0000000000ad"
}

variable "ado_project" {
  type    = string
  default = "purview-config"
}

variable "ado_issuer_mode" {
  description = "entra (default, Microsoft Entra issuer) or legacy (vstoken.dev.azure.com, deprecated)."
  type        = string
  default     = "entra"
}

variable "ado_subjects" {
  description = "entra mode: role => Subject identifier shown on the draft ADO service connection. Roles without a subject get no ADO FIC yet."
  type        = map(string)
  default     = {}
}

variable "use_self_hosted_mi" {
  description = "Trust a user-assigned managed identity on self-hosted agents for deployers instead of ADO OIDC."
  type        = bool
  default     = false
}

variable "agent_pool_mi_principal_ids" {
  description = "Principal (object) IDs of one UAMI per deployer role attached to dedicated self-hosted agent pools."
  type        = map(string)
  default = {
    dlp        = "00000000-0000-0000-0000-0000000000b1"
    retention  = "00000000-0000-0000-0000-0000000000b2"
    classifier = "00000000-0000-0000-0000-0000000000b3"
    rbac       = "00000000-0000-0000-0000-0000000000b4"
  }
}

locals {
  roles     = ["reader", "dlp", "retention", "classifier", "rbac"]
  deployers = ["dlp", "retention", "classifier", "rbac"]

  ado_fic = [
    for r in local.roles : {
      role                   = r
      name                   = "ado-sc-ppdf-prod-${r}"
      type                   = "azure-devops"
      ado_issuer_mode        = var.ado_issuer_mode
      subject                = var.ado_issuer_mode == "entra" ? lookup(var.ado_subjects, r, null) : null
      ado_organization       = var.ado_organization
      ado_organization_id    = var.ado_organization_id
      ado_project            = var.ado_project
      ado_service_connection = "sc-ppdf-prod-${r}"
    } if(r == "reader" || !var.use_self_hosted_mi) && (var.ado_issuer_mode == "legacy" || contains(keys(var.ado_subjects), r))
  ]

  mi_fic = var.use_self_hosted_mi ? [
    for r in local.deployers : {
      role                          = r
      name                          = "uami-agentpool-${r}"
      type                          = "managed-identity"
      managed_identity_principal_id = var.agent_pool_mi_principal_ids[r]
    }
  ] : []
}

module "ppdf_identities" {
  source                = "../../modules/ppdf-identities"
  name_prefix           = "ppdf-prod"
  tenant_id             = var.tenant_id
  federated_credentials = concat(local.ado_fic, local.mi_fic)
}

output "environment_identities" { value = module.ppdf_identities.environment_identities }
output "grant_input" { value = module.ppdf_identities.grant_input }
output "approver_group_ids" { value = module.ppdf_identities.approver_group_ids }
output "next_steps" { value = module.ppdf_identities.next_steps }
