# PPDF identities

PPDF deploys with **purpose-specific, least-privilege workload identities**. Each tenant or environment gets one
read-only identity plus one deployer per workload. There are no secrets: trust is federated from the orchestrator.
See [docs/identities.md](../docs/identities.md) for the decision guide and [roles-matrix.yml](roles-matrix.yml)
for the exact permissions.

| Identity | Used for | Entra | Purview role group |
|---|---|---|---|
| `reader` | validate, plan, simulation report, drift, export | Exchange.ManageAsApp, Graph `RoleEligibilitySchedule.Read.Directory`, `RoleAssignmentSchedule.Read.Directory` | `<PREFIX>_READER` (view-only roles) |
| `dlp` | DLP policies and rules | Exchange.ManageAsApp | `<PREFIX>_DLP`: DLP Compliance Management |
| `retention` | retention policies, rules and labels | Exchange.ManageAsApp | `<PREFIX>_RETENTION`: Retention Management (+ Record Management) |
| `classifier` | custom SIT rule packages | Exchange.ManageAsApp | `<PREFIX>_CLASSIFIER`: DLP Compliance Management |
| `rbac` | Purview role groups, Entra PIM eligibility | Exchange.ManageAsApp, Graph `RoleEligibilitySchedule.ReadWrite.Directory`, `RoleAssignmentSchedule.ReadWrite.Directory` | `<PREFIX>_RBAC`: Role Management |

## Layout

```
identities/
├─ roles-matrix.yml                    # identity → operations → roles/permissions (with verify status)
├─ terraform/
│  ├─ modules/ppdf-identities/         # apps, SPs, app role grants, federated credentials, approver groups
│  └─ examples/{github,azure-devops,terraform-cloud}/
├─ powershell/
│  ├─ New-PpdfIdentities.ps1           # Graph-only alternative to Terraform
│  └─ Grant-PpdfPurviewRoles.ps1       # Purview role groups (Terraform cannot manage these)
└─ agent-id/                           # Entra Agent ID for autonomous helper agents (read-only, preview)
```

## Quick start (GitHub Actions)

```bash
# 1. Entra objects. Run as Application Administrator plus a role that can grant app permissions
#    (for example Privileged Role Administrator).
cd identities/terraform/examples/github
terraform init && terraform apply -var tenant_id=<tid> -var github_repository=<owner>/<repo>
terraform output -json grant_input > grant.json
terraform output environment_identities      # paste into environments/prod.yml → spec.identities
```

```powershell
# 2. Purview role groups. Run as a Purview admin with Role Management (activate via PIM).
./identities/powershell/Grant-PpdfPurviewRoles.ps1 -InputFile grant.json -Organization contoso.onmicrosoft.com -WhatIf
./identities/powershell/Grant-PpdfPurviewRoles.ps1 -InputFile grant.json -Organization contoso.onmicrosoft.com
```

3. In GitHub, create the environments `prod-read` (no reviewers) and `prod-low`, `prod-standard`, `prod-elevated` and
   `prod-critical`. Give each tier its own required reviewers and turn on "prevent self-review". The federated
   credentials trust exactly these environment names.

If you do not use Terraform, run `New-PpdfIdentities.ps1` for step 1. It is idempotent and supports `-WhatIf`.

## Rules

- Never add PPDF identities to built-in role groups (Compliance Administrator, Organization Management), and
  never give them standing Entra directory roles.
- One identity per purpose and environment family. Revoking one does not affect the others.
- Changing a federated credential subject (repo, environment or service connection) is a security change. Review it like code.
