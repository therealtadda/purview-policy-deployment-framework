variable "name_prefix" {
  description = "Prefix for app registrations and groups, e.g. 'ppdf-prod'. One set of identities per tenant/environment is recommended."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must be 2-31 lowercase letters, digits or hyphens."
  }
}

variable "tenant_id" {
  description = "Entra tenant ID. Used for managed-identity federated credential issuers."
  type        = string
}

variable "roles" {
  description = <<-EOT
    Identity roles to create. Phase 1 roles: reader, dlp, retention, classifier, rbac.
    Each role becomes one app registration + service principal that is used only for that purpose.
  EOT
  type        = set(string)
  default     = ["reader", "dlp", "retention", "classifier", "rbac"]
  validation {
    condition     = alltrue([for r in var.roles : contains(["reader", "dlp", "retention", "classifier", "rbac"], r)])
    error_message = "Supported roles are reader, dlp, retention, classifier, rbac. Phase 2 roles (edm, labels, irm) are not yet implemented."
  }
}

variable "graph_app_roles_override" {
  description = "Optional override of the Microsoft Graph application permissions per role. Leave empty to use the least-privilege defaults in locals.tf."
  type        = map(list(string))
  default     = {}
}

variable "owners" {
  description = "Object IDs of owners for the app registrations and groups (e.g. the platform team). Owners can manage credentials, so keep this list short."
  type        = list(string)
  default     = []
}

variable "notes" {
  description = "Free-text notes stored on each app registration (e.g. CMDB or change reference)."
  type        = string
  default     = "Managed by Terraform (ppdf-identities). Purpose-specific Purview deployment identity."
}

variable "federated_credentials" {
  description = <<-EOT
    Federated identity credentials (workload identity federation). One entry per role per trust.
    type is one of: github | azure-devops | terraform-cloud | managed-identity | custom.
      github:           github_repository (org/repo) + github_environment  -> repo:<org/repo>:environment:<env>
      azure-devops:     ado_issuer_mode = "entra" (default): issuer https://login.microsoftonline.com/<tenant>/v2.0 and an
                        explicit `subject` copied from the draft service connection (ADO generates it).
                        ado_issuer_mode = "legacy": ado_organization + ado_organization_id + ado_project +
                        ado_service_connection -> sc://<org>/<project>/<sc> with issuer vstoken.dev.azure.com
                        (deprecated by Azure DevOps; retires 2027-07-01 - convert existing connections).
      terraform-cloud:  tfc_organization + tfc_project + tfc_workspace + tfc_run_phase (plan|apply)
      managed-identity: managed_identity_principal_id (object/principal ID of a user-assigned managed identity)
      custom:           issuer + subject
  EOT
  type = list(object({
    role                          = string
    name                          = string
    type                          = string
    audiences                     = optional(list(string), ["api://AzureADTokenExchange"])
    github_repository             = optional(string)
    github_environment            = optional(string)
    ado_issuer_mode               = optional(string, "entra")
    ado_organization              = optional(string)
    ado_organization_id           = optional(string)
    ado_project                   = optional(string)
    ado_service_connection        = optional(string)
    tfc_hostname                  = optional(string, "app.terraform.io")
    tfc_organization              = optional(string)
    tfc_project                   = optional(string)
    tfc_workspace                 = optional(string)
    tfc_run_phase                 = optional(string)
    managed_identity_principal_id = optional(string)
    issuer                        = optional(string)
    subject                       = optional(string)
  }))
  default = []
  validation {
    condition     = alltrue([for c in var.federated_credentials : contains(["github", "azure-devops", "terraform-cloud", "managed-identity", "custom"], c.type)])
    error_message = "federated_credentials[*].type must be github, azure-devops, terraform-cloud, managed-identity or custom."
  }
  validation {
    condition     = length(var.federated_credentials) == length(distinct([for c in var.federated_credentials : "${c.role}/${c.name}"]))
    error_message = "federated_credentials role/name pairs must be unique."
  }
  validation {
    condition     = alltrue([for c in var.federated_credentials : contains(var.roles, c.role)])
    error_message = "Every federated_credentials[*].role must be listed in var.roles."
  }
  validation {
    condition     = alltrue([for c in var.federated_credentials : c.type != "terraform-cloud" || contains(["plan", "apply"], coalesce(c.tfc_run_phase, "missing"))])
    error_message = "terraform-cloud credentials need tfc_run_phase = plan | apply."
  }
  validation {
    condition = alltrue([for c in var.federated_credentials : c.type != "azure-devops" || (
      contains(["entra", "legacy"], coalesce(c.ado_issuer_mode, "entra")) &&
      (coalesce(c.ado_issuer_mode, "entra") == "legacy" || c.subject != null)
    )])
    error_message = "azure-devops credentials: ado_issuer_mode must be entra|legacy; entra mode needs the subject shown on the ADO service connection."
  }
}

variable "create_approver_groups" {
  description = "Create one Entra security group per workload for human approvers (referenced by pipeline environments / TFC teams)."
  type        = bool
  default     = true
}

variable "approver_group_members" {
  description = "Optional initial members (object IDs) per approver group key: dlp, retention, classifier, rbac, prod."
  type        = map(list(string))
  default     = {}
}
