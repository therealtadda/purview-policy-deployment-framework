data "azuread_service_principal" "exchange" {
  client_id = local.exchange_online_app_id
}

data "azuread_service_principal" "graph" {
  client_id = local.microsoft_graph_app_id
}

# One app registration per purpose. No secrets are ever created; authentication is workload identity
# federation (or a certificate uploaded out of band for orchestrators without OIDC).
resource "azuread_application" "this" {
  for_each                = var.roles
  display_name            = "${var.name_prefix}-${each.key}"
  description             = local.descriptions[each.key]
  notes                   = var.notes
  owners                  = var.owners
  sign_in_audience        = "AzureADMyOrg"
  prevent_duplicate_names = true

  # Declared permissions (shown in the portal); the grants themselves are the app role assignments below.
  required_resource_access {
    resource_app_id = local.exchange_online_app_id
    resource_access {
      id   = data.azuread_service_principal.exchange.app_role_ids["Exchange.ManageAsApp"]
      type = "Role"
    }
  }

  dynamic "required_resource_access" {
    for_each = length(local.graph_app_roles[each.key]) > 0 ? [1] : []
    content {
      resource_app_id = local.microsoft_graph_app_id
      dynamic "resource_access" {
        for_each = local.graph_app_roles[each.key]
        content {
          id   = data.azuread_service_principal.graph.app_role_ids[resource_access.value]
          type = "Role"
        }
      }
    }
  }

  tags = ["ppdf", "ppdf-role:${each.key}"]
}

resource "azuread_service_principal" "this" {
  for_each                     = var.roles
  client_id                    = azuread_application.this[each.key].client_id
  owners                       = var.owners
  app_role_assignment_required = true
  notes                        = local.descriptions[each.key]
  tags                         = ["ppdf", "ppdf-role:${each.key}"]
}

# Exchange.ManageAsApp lets the app connect to Security & Compliance PowerShell app-only.
# It grants no Purview permissions by itself; those come only from the custom role group (see outputs.next_steps).
resource "azuread_app_role_assignment" "exchange_manage_as_app" {
  for_each            = var.roles
  app_role_id         = data.azuread_service_principal.exchange.app_role_ids["Exchange.ManageAsApp"]
  principal_object_id = azuread_service_principal.this[each.key].object_id
  resource_object_id  = data.azuread_service_principal.exchange.object_id
}

resource "azuread_app_role_assignment" "graph" {
  for_each            = local.graph_assignments
  app_role_id         = data.azuread_service_principal.graph.app_role_ids[each.value.permission]
  principal_object_id = azuread_service_principal.this[each.value.role].object_id
  resource_object_id  = data.azuread_service_principal.graph.object_id
}

resource "azuread_application_federated_identity_credential" "this" {
  for_each       = local.fic
  application_id = azuread_application.this[each.value.role].id
  display_name   = replace(each.value.name, "/[^A-Za-z0-9-_]/", "-")
  description    = "PPDF ${each.value.type} trust for role ${each.value.role}"
  audiences      = each.value.audiences
  issuer         = each.value.resolved_issuer
  subject        = each.value.resolved_subject
}

# Human approvers. Reference these groups from GitHub environment reviewers (via team sync), Azure DevOps
# environment approvals or Terraform Cloud team access. Approvers must never be members of the deployer identities' owners.
resource "azuread_group" "approvers" {
  for_each         = local.approver_groups
  display_name     = "${var.name_prefix}-approvers-${each.key}"
  description      = each.key == "prod" ? "PPDF production promotion approvers" : "PPDF ${each.key} change approvers"
  security_enabled = true
  owners           = length(var.owners) > 0 ? var.owners : null
  members          = lookup(var.approver_group_members, each.key, [])
}
