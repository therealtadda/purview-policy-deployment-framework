# Entra Agent ID identities for PPDF agents

> **Preview.** Microsoft Entra Agent ID is in preview. The endpoints, permissions and token flow below follow
> Microsoft Learn at the time of writing. Verify them before production use.

PPDF can be helped by autonomous agents. They must never become a way around the pipeline's human approval.
This folder provisions their identities only. The agent runtimes are planned for a later phase.

| Agent | Does | Never does |
|---|---|---|
| `ppdf-sim-analyst` | Reads the simulation report artefact. Summarises match volumes, false-positive hot spots and risk, then comments on the PR. | Change Purview, approve deployments, push to protected branches |
| `ppdf-drift-agent` | Reads drift/export output from the scheduled reader job. Opens a PR that codifies or reverts the drift. | Apply anything; the normal plan → approval → apply path does that |

## Why an Agent ID rather than another app registration

- **Accountability.** Each agent identity has **sponsors**: named humans or groups who answer for it.
  Lifecycle reviews and governance features treat agent identities as their own class.
- **Scale and hygiene.** One **blueprint** holds the credential, a federated trust to the managed identity of the
  agent host. Each agent identity has no credential of its own, so adding an agent adds no secret.
- **Policy targeting.** Conditional Access and ID Protection can target agent identities separately from
  workload identities used by pipelines.

Use ordinary workload identities (`identities/terraform`) for pipeline deployers. Pipelines are deterministic,
reviewed code and are gated by environment approvals. Use Agent ID for non-deterministic, LLM-driven actors.

## Least privilege

By default the agents get **no Purview or Graph permissions**. They work only on artefacts the pipeline's reader
identity already produced (`ppdf-plan.json`, `simulation-report.json`, `drift.json`). Their only write path is the code host:
a GitHub App or PAT scoped to issues and pull requests, with branch protection. As a result:

- an agent can *propose* (a PR, or a comment on one) but cannot *deploy*;
- every change still passes the pipeline's tier-based approval environments, where humans review it.

If an agent really must query Purview, run the script with `-GrantPurviewRead`. This grants `Exchange.ManageAsApp` plus the reader's Graph
read permissions and writes a grant file. Then run
`identities/powershell/Grant-PpdfPurviewRoles.ps1 -InputFile ppdf-agent-grant.json`. This creates a separate
`<PREFIX>_AGENTS_READ` role group with the reader's view-only roles. Agents never get write roles.
(Verify that Security & Compliance PowerShell accepts agent identity tokens in your tenant.)

## Provisioning

Prerequisites:

- A user-assigned managed identity on the agent host, such as Container Apps, Functions or a VM.
- The caller holds **Agent ID Administrator**, or **Agent ID Developer** for blueprints they own.
- With `-GrantPurviewRead`, the caller also needs a role that can grant application permissions.
- Sponsors are users, or Microsoft 365 or dynamic groups. Security groups are not supported as sponsors.

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
./identities/agent-id/New-PpdfAgentIdentities.ps1 `
  -TenantId 00000000-0000-0000-0000-000000000000 `
  -SponsorUserIds 00000000-0000-0000-0000-000000000001 `
  -ManagedIdentityPrincipalId 00000000-0000-0000-0000-000000000002 `
  -WhatIf
```

What gets created:

| Object | Endpoint |
|---|---|
| Blueprint `ppdf-agents` | `POST /v1.0/applications/microsoft.graph.agentIdentityBlueprint` |
| Blueprint principal | `POST /v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal` |
| Managed identity FIC on the blueprint | `POST /v1.0/applications/{id}/federatedIdentityCredentials` (issuer `https://login.microsoftonline.com/<tid>/v2.0`, subject = managed identity principal ID) |
| Agent identities | `POST /beta/servicePrincipals/microsoft.graph.agentIdentity` |

## Runtime token flow

1. The agent host gets a managed identity token for audience `api://AzureADTokenExchange`.
2. It exchanges that for a **blueprint** token: `client_credentials`, `client_id=<blueprint appId>`,
   `client_assertion=<MI token>`, `scope=api://AzureADTokenExchange/.default`, `fmi_path=<agent identity client id>`.
3. It exchanges the blueprint token for the **agent identity** token for the target resource:
   `client_id=<agent client id>`, `client_assertion=<blueprint token>`, `scope=<resource>/.default`.

## Conditional Access and governance

- Create a Conditional Access policy for agent identities. Restrict to the agent host's network or locations where
  supported, and block high agent risk.
- Review sponsors and agent identities on a schedule. Remove agent identities whose agent is retired.
- Monitor sign-in logs (agent sign-ins) and the audit log for any use of agent identities beyond reading artefacts.
