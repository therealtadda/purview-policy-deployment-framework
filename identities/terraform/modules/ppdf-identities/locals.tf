locals {
  # Well-known first-party application IDs.
  exchange_online_app_id = "00000002-0000-0ff1-ce00-000000000000" # Office 365 Exchange Online (hosts Exchange.ManageAsApp, used by Security & Compliance PowerShell)
  microsoft_graph_app_id = "00000003-0000-0000-c000-000000000000"

  # Least-privilege Microsoft Graph application permissions per role.
  # Only the rbac workload (EntraRoleAssignment kind) calls Graph in Phase 1; every other role is Graph-less.
  # reader lists PIM schedules for plan/drift; rbac creates schedule requests (eligible and active).
  default_graph_app_roles = {
    reader     = ["RoleEligibilitySchedule.Read.Directory", "RoleAssignmentSchedule.Read.Directory"]
    dlp        = []
    retention  = []
    classifier = []
    rbac       = ["RoleEligibilitySchedule.ReadWrite.Directory", "RoleAssignmentSchedule.ReadWrite.Directory"]
  }

  descriptions = {
    reader     = "Read-only: plan, simulation reports, drift and export. Never writes."
    dlp        = "Writes DLP policies and rules only."
    retention  = "Writes retention policies, rules and retention labels only."
    classifier = "Writes custom sensitive information type rule packages only."
    rbac       = "Writes Purview role groups and requests Entra PIM eligibility (allowlisted roles) only."
  }

  # Purview (Security & Compliance) role group each service principal is added to by
  # identities/powershell/Grant-PpdfPurviewRoles.ps1. Terraform cannot manage S&C RBAC.
  purview_role_groups = { for r in var.roles : r => "${upper(replace(var.name_prefix, "-", "_"))}_${upper(r)}" }

  graph_app_roles = { for r in var.roles : r => lookup(var.graph_app_roles_override, r, local.default_graph_app_roles[r]) }

  graph_assignments = merge([
    for r in var.roles : { for p in local.graph_app_roles[r] : "${r}/${p}" => { role = r, permission = p } }
  ]...)

  fic = {
    for c in var.federated_credentials : "${c.role}/${c.name}" => merge(c, {
      resolved_issuer = coalesce(c.issuer, lookup({
        github             = "https://token.actions.githubusercontent.com"
        "azure-devops" = c.ado_issuer_mode == "legacy" ? try("https://vstoken.dev.azure.com/${c.ado_organization_id}", null) : "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
        "terraform-cloud"  = try("https://${c.tfc_hostname}", null)
        "managed-identity" = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
      }, c.type, null))
      resolved_subject = coalesce(c.subject, lookup({
        github             = try("repo:${c.github_repository}:environment:${c.github_environment}", null)
        "azure-devops" = c.ado_issuer_mode == "legacy" ? try("sc://${c.ado_organization}/${c.ado_project}/${c.ado_service_connection}", null) : null
        "terraform-cloud"  = try("organization:${c.tfc_organization}:project:${c.tfc_project}:workspace:${c.tfc_workspace}:run_phase:${c.tfc_run_phase}", null)
        "managed-identity" = c.managed_identity_principal_id
      }, c.type, null))
    })
  }

  approver_groups = var.create_approver_groups ? toset(concat([for r in var.roles : r if r != "reader"], ["prod"])) : toset([])
}
