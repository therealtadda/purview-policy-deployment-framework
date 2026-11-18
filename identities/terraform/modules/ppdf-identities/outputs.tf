output "client_ids" {
  description = "Application (client) ID per role."
  value       = { for r, a in azuread_application.this : r => a.client_id }
}

output "service_principal_object_ids" {
  description = "Service principal object ID per role (needed by New-ServicePrincipal / Add-RoleGroupMember in Security & Compliance PowerShell)."
  value       = { for r, sp in azuread_service_principal.this : r => sp.object_id }
}

output "environment_identities" {
  description = "Paste into spec.identities of the PPDF environment file (add authMode / adoServiceConnectionId as needed)."
  value       = { for r, a in azuread_application.this : r => { clientId = a.client_id } }
}

output "purview_role_groups" {
  description = "Custom Purview role group name per role, consumed by identities/powershell/Grant-PpdfPurviewRoles.ps1."
  value       = local.purview_role_groups
}

output "approver_group_ids" {
  description = "Object ID per approver group."
  value       = { for k, g in azuread_group.approvers : k => g.object_id }
}

output "grant_input" {
  description = "JSON input for Grant-PpdfPurviewRoles.ps1 -InputFile (terraform output -json grant_input > grant.json)."
  value = {
    for r in var.roles : r => {
      appId       = azuread_application.this[r].client_id
      objectId    = azuread_service_principal.this[r].object_id
      displayName = azuread_application.this[r].display_name
      roleGroup   = local.purview_role_groups[r]
    }
  }
}

output "next_steps" {
  description = "Manual steps Terraform cannot perform."
  value       = <<-EOT
    1. terraform output -json grant_input > grant.json
    2. As a Purview Role Management admin (PIM-activated), run:
       ./identities/powershell/Grant-PpdfPurviewRoles.ps1 -InputFile grant.json -Organization <tenant>.onmicrosoft.com
       This registers each service principal in Security & Compliance and adds it to its custom role group.
    3. Copy environment_identities into environments/<env>.yml (spec.identities).
    4. Configure orchestrator approvals with approver_group_ids (see docs/identities.md and docs/approvals.md).
  EOT
}
