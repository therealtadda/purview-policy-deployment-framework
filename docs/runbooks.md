# Operator runbooks

Step-by-step procedures for common PPDF operations. Each runbook works the same in every orchestrator. The CLI
commands are shown so you can also run them locally. In the pipelines, the same commands are chosen with the
`command` input (GitHub) or parameter (Azure DevOps), or the `command` variable (Terraform).

- [Adopt existing (brownfield) configuration](#adopt-existing-brownfield-configuration)
- [First deployment to a new environment](#first-deployment-to-a-new-environment)
- [Promote from simulation to enforcement](#promote-from-simulation-to-enforcement)
- [An apply was refused, blocked, stale or failed](#an-apply-was-refused-blocked-stale-or-failed)
- [Undo a change](#undo-a-change)
- [Drift was detected](#drift-was-detected)
- [Rotate or replace an identity or credential](#rotate-or-replace-an-identity-or-credential)
- [A change needs a higher approval tier](#a-change-needs-a-higher-approval-tier)
- [Remove an artifact](#remove-an-artifact)

Exit codes used below: `0` nothing pending, `2` changes pending, `3` stopped by a safety gate, `1` error.

---

## Adopt existing (brownfield) configuration

Use this when the tenant already has DLP policies, retention policies, custom SITs or role groups that you want
PPDF to manage. PPDF never touches an object it doesn't own: an existing object with the same name is blocked
until you adopt it.

1. **Export** what exists, to a folder outside `config/`. Run as the reader, or with your own session before the
   reader exists:

   ```powershell
   ./cli/ppdf.ps1 export -Environment prod -Kind DlpPolicy,RetentionPolicy -OutputPath ./export
   # or: Connect-IPPSSession -UserPrincipalName admin@contoso.com; Invoke-PpdfExport -Environment prod -UseExistingConnection -OutputPath ./export
   ```

   Each file carries `metadata.adopt: true`. Some objects aren't exported: Microsoft SIT packages, `-ppdfsim`
   shadow copies, retention policies that publish labels or have several rules, and Entra roles outside the
   allowlist. Role groups that PPDF didn't create are exported as `membershipOnly: true`.
2. **Tidy** the files: replace tenant-specific values with `${variables}`, set `metadata.environments` and
   `owner`, and delete anything you don't want to manage. Don't change the settings yet.
3. **Move** them under `config/artifacts/` and validate: `./cli/ppdf.ps1 validate`.
4. **Plan at the current stage**, so live policies stay live:

   ```powershell
   ./cli/ppdf.ps1 plan -Environment prod -Stage auto -OutputPath ./out/adopt
   ```

   Expect only `adopt` actions (`elevated` tier), each changing nothing but the ownership tag. If an action lists
   other `diffKeys`, the file differs from the tenant: fix the file, not the tenant, and plan again.
5. **Apply through the pipeline** (manual run, `command: plan`, `stage: auto`). Reviewers check that `plan.md`
   only adopts.
6. **Remove `adopt: true`** from the files in a follow-up pull request. From now on, normal changes go through
   simulation as usual; changes to a live DLP policy are simulated with a shadow copy.

Adopt one workload at a time in production, starting with dev or test if those tenants have the same objects.

## First deployment to a new environment

1. Create the identities and grant their Purview roles ([identities](identities.md#provisioning-order)).
2. Create the approval gates (`<env>-read` and `<env>-<tier>`) in the orchestrator ([adapters](adapters.md)).
3. Add `config/environments/<env>.yml` with the tenant, `spec.identities` and `approvals`, and validate it.
4. If the tenant already has configuration you will manage, [adopt it](#adopt-existing-brownfield-configuration)
   first.
5. Run the pipeline with `command: plan`, `stage: simulate`. Review `plan.md`, approve at the named gate and let
   apply run.
6. Smoke test: the plan must succeed as the reader, and a second plan right after the apply must exit `0`.

## Promote from simulation to enforcement

1. Wait for the soak period (`spec.simulation.minSoakHours`; Activity Explorer can lag by hours).
2. Check the evidence:

   ```powershell
   ./cli/ppdf.ps1 simulation-report -Environment prod -OutputPath ./out/sim
   ```

   Exit `0` means every artifact is ready. Exit `3` means at least one is `fail`, `soaking`, `missing` or
   `stale`; read `simulation-report.md` (see [report statuses](lifecycle.md#simulation-report-statuses)). Query
   the details with PowerShell as shown in [querying simulation results](lifecycle.md#querying-simulation-results).
3. Run the pipeline with `command: promote`. Promote generates a fresh report and plans enforcement for every
   artifact in simulation. Any artifact without passing evidence is a blocked action, and a plan with a blocked
   action cannot be applied, so promote when step 2 exits `0`. To check a single artifact first, run
   `./cli/ppdf.ps1 promote -Environment prod -Artifact <name>` as the reader.
4. Approvers review `plan.md` and the attached simulation report. Promotion usually needs `elevated`.
5. For policies that were simulated with a shadow copy (`<name>-ppdfsim`), the same plan updates the real policy
   and removes the shadow copy.

If an artifact keeps failing a threshold, change the artifact (rules, scope) and start again from simulation, or
raise its `simulation.thresholds` in a reviewed pull request if the volume is expected.

## An apply was refused, blocked, stale or failed

Read the job summary or `apply-result.md` first. Never edit a plan file; always plan again.

| What you see | Meaning | What to do |
|---|---|---|
| Plan exits `3`, actions listed as blocked | A safety rule stopped the action before approval. | Fix the cause listed in `plan.md` ([blocked actions](lifecycle.md#blocked-actions)) and plan again. |
| Apply exits `3`, "refused" | Hash mismatch, blocked actions, the gate's tier is lower than the plan's, or the plan is older than `approvals.maxPlanAgeHours`. Nothing changed. | Run plan again and approve the new plan at the gate it names. If the tier is wrong, see [higher approval tier](#a-change-needs-a-higher-approval-tier). |
| Workload `skipped-stale` | The tenant changed between plan and apply (a portal edit or another run). Nothing in that workload changed. | Plan again and review what changed. If someone edited the portal, treat it as [drift](#drift-was-detected). |
| Action `failed`, rest `not-run` | A cmdlet failed. Actions before it succeeded; the remaining actions and workloads did not run. | Read the log in `evidence/`. Fix the cause (permissions, a Purview limit, a transient error) and plan again: the new plan contains only what is still missing. To return to the previous state instead, [roll back](#undo-a-change). |
| Exit `1` at sign-in | The identity couldn't get a token or open a session. | Check the federated credential subject against the gate name, the client ID in `spec.identities`, and role group membership. |

## Undo a change

There are two ways back. Prefer the first.

**Revert the commit.** Revert the pull request, merge it and let the normal pipeline plan and apply it. This
keeps config and tenant in step and goes through simulation where possible.

**Roll back a deployment.** Use it for fast recovery when the change itself is the problem and you can't wait
for a revert to simulate:

1. Find the run that applied the change (its evidence artifact holds `plan.json` and `apply-result.json`).
2. Run the deployment pipeline with `command: rollback`, the same environment and the run ID
   (`rollback-run-id` in GitHub, `rollbackRunId` in Azure DevOps). Locally:

   ```powershell
   ./cli/ppdf.ps1 rollback -PlanPath ./evidence/plan.json -ApplyResultPath ./evidence/apply-result.json -OutputPath ./out/rollback
   ```

3. Review `rollback-plan.md`. Created objects are deleted, updated properties are restored and deleted objects
   are recreated. It always needs `elevated` approval or higher.
4. Apply it. Then revert the commit as well, or the next plan will reapply the change.

Rollback doesn't undo data-plane effects: content already labelled, retained or blocked stays that way. Rollback
needs the evidence artifact, so keep it for as long as you may need to roll back. The Terraform adapter has no
rollback command; revert the commit instead.

## Drift was detected

The scheduled pipeline opens or updates an issue labelled `ppdf-drift` with `drift.md`. For each item decide:

- **Revert the tenant to config:** run the pipeline with `command: drift`, review `drift.md`, approve and apply.
  The drift plan is a normal plan.
- **Keep the portal change:** export the kind, copy the changed fields into the artifact and merge the pull
  request. The next drift check is clean.

  ```powershell
  ./cli/ppdf.ps1 export -Environment prod -Kind DlpPolicy -OutputPath ./export
  ```

- **Managed object deleted outside PPDF:** the drift plan recreates it. If the deletion was intended, remove the
  artifact ([below](#remove-an-artifact)).
- **Orphan** (tagged by PPDF, but no artifact): restore the artifact, or remove the object deliberately.

Find out who made the change in the Purview audit log, and consider removing their direct role if changes should
go only through PPDF.

## Rotate or replace an identity or credential

Federated and managed identity credentials have no secrets to rotate. You rotate when something changes:

| Change | Steps |
|---|---|
| Repository, environment, service connection or workspace renamed | Update the federated credential subjects (re-apply the [identities Terraform](../identities/terraform/modules/ppdf-identities)); the old subject stops working immediately. Entra allows at most 20 federated credentials per app. |
| Azure DevOps legacy issuer (`vstoken.dev.azure.com`) | Convert each service connection to the Entra issuer before 2027-07-01, then update `ado_issuer_mode` and re-apply. |
| Certificate (`authMode: certificate`) | Create the new certificate in Key Vault, append its public key to the app, update `certificateThumbprint` (or the `PPDF_CERT_*` secrets), run a plan to confirm sign-in, then remove the old key from the app. |
| Replace an identity (new app) | Create the new app, add it to the grant file and run `Grant-PpdfPurviewRoles.ps1`. Update `clientId` in `spec.identities` by pull request and run a plan. Then remove the old service principal from its role group (`Remove-RoleGroupMember`) and delete the old app. |
| Suspected compromise | Disable the app's service principal first (it stops all sign-ins), then investigate sign-in and audit logs, and replace it as above. |

After any change, run a plan as the reader and confirm the deployers still can't get a token outside the gated
job.

## A change needs a higher approval tier

- **The plan names a gate that doesn't exist** (for example `prod-critical`): create the gate with the right
  reviewers ([adapters](adapters.md#choosing-the-gate)). Never lower the plan's tier to fit the gates you have.
- **Apply refused because the approved tier was too low:** the job ran behind a lower gate than the plan
  requires. Fix the pipeline so the gate comes from the plan's `approval_environment`, then plan again.
- **Terraform:** raise `approved_tier` in a pull request reviewed by the approvers of that tier, then run again.
- **Make an artifact always need more review:** set `metadata.riskTier: elevated` (or `critical`) on the
  artifact. It raises, never lowers, the tier of every change to that artifact.

## Remove an artifact

**Recommended: `ensure: absent`.** Keep the file, set `metadata.ensure: absent` and open a pull request. The
removal is visible in review and the plan deletes the object (and its rules). Deleting a top-level object needs
`critical` approval. Once applied, delete the file in a later pull request.

**Deleting the file.** The object becomes an orphan: the next plan lists its deletion as blocked unless
`spec.allowDestructive: true` is set for the environment, and even then it needs `critical` approval. Use this
only for bulk clean-up, and turn `allowDestructive` off again afterwards.

Before removing a DLP or retention policy, check what depends on it: removing a retention policy can let content
be deleted sooner, and a Preservation Lock policy cannot be removed at all.
