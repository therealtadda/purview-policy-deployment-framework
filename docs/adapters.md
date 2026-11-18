# Orchestrator adapters

PPDF runs in any orchestrator: the engine is a PowerShell module plus a CLI (`cli/ppdf.ps1`). An *adapter* is the
thin layer of pipeline code that:

- runs the CLI as the right identity at each step;
- shows the plan to a human and waits for approval;
- carries the approved plan to the apply step.

Phase 1 ships adapters for GitHub Actions, Azure DevOps Pipelines and Terraform. This page explains the contract
every adapter follows, how to set up each one, and how to build an adapter for another orchestrator.

- [The adapter contract](#the-adapter-contract)
- [GitHub Actions](#github-actions)
- [Azure DevOps Pipelines](#azure-devops-pipelines)
- [Terraform](#terraform)
- [Building an adapter for another orchestrator](#building-an-adapter-for-another-orchestrator)

---

## The adapter contract

### Steps and identities

| Step | CLI command | Identity | Gate |
|---|---|---|---|
| Validate | `validate` | none (offline) | — |
| Plan | `plan`, `promote`, `drift` or `rollback` | reader (view-only; `rollback` is offline) | — |
| Report | `simulation-report` | reader | — |
| Approve | — | a human | the orchestrator's approval feature |
| Apply | `apply` | one deployer per workload (`dlp`, `retention`, `classifier`, `rbac`) | runs only after approval |

**A write identity must not be able to get a token before approval.** Each adapter binds the deployer
identities to the gated step, not to the pipeline as a whole:

- **GitHub:** the deployer apps trust only the OIDC subject `environment:<env>-<tier>`, and GitHub only issues
  that token after a reviewer approves the environment.
- **Azure DevOps:** the deployer service connections are used only by deployment jobs that target an environment
  with an Approvals check.
- **Terraform:** the deployer apps trust only the `run_phase:apply` token, which exists only after "Confirm &
  apply".

See [identities](identities.md#choosing-an-identity-type) for the identity types and
[federated credential subjects](identities.md#federated-credential-subjects) for the exact trust settings.

### Passing the plan to apply

The plan step writes these files to its output folder; the adapter publishes them as a pipeline artifact:

| File | Purpose |
|---|---|
| `plan.json` (`promote` also writes `plan.json`; `drift` writes `drift.json`; `rollback` writes `rollback-plan.json`) | The plan document that apply runs. |
| `<plan>.json.sha256` | SHA-256 sidecar. |
| `<plan>.md` | Human-readable plan for the approver. |
| `simulation-report.*` | When the command produced a simulation report. |

The adapter then calls apply with:

```powershell
./cli/ppdf.ps1 apply -PlanPath <artifact>/plan.json -ExpectedPlanHash <plan_hash from the plan step> `
    -ApprovedTier <tier of the gate that approved this job> -Workload <workload> -OutputPath out/apply
```

Apply refuses (exit 3, nothing changed) when the hash doesn't match the sidecar or `-ExpectedPlanHash`, when the
plan has blocked actions, when `-ApprovedTier` is lower than the plan requires, or when the plan is older than
`approvals.maxPlanAgeHours`. It then re-reads every object and skips a workload as `skipped-stale` if the tenant
changed since the plan. See [apply safety checks](lifecycle.md#apply-safety-checks).

### Choosing the gate

The plan reports its required tier (`approval_tier`) and the gate name (`approval_environment`), built from
`approvals.pattern` in the environment file (default `{env}-{tier}`). Create one gate per tier and staff them
accordingly:

| Gate | Typical reviewers |
|---|---|
| `<env>-low` | None needed (empty plans); keep it for symmetry. |
| `<env>-standard` | One member of the owning compliance team. |
| `<env>-elevated` | Two reviewers, including a Purview administrator; self-review blocked. |
| `<env>-critical` | Senior compliance or records-management owner plus a security reviewer; consider business-hours checks. |

What lands in each tier is listed in [approval tiers](lifecycle.md#approval-tiers).

### Exit codes and outputs

| Exit code | Meaning | Typical adapter behaviour |
|---|---|---|
| `0` | Nothing pending (or apply succeeded). | Skip apply. |
| `2` | Changes or drift pending. | Continue to the approval gate. |
| `3` | Blocked actions, refused apply or failed simulation gate. | Fail the job (or report only, for scheduled checks). |
| `1` | Error. | Fail the job. |

The CLI detects GitHub Actions (`GITHUB_ACTIONS`) and Azure DevOps (`TF_BUILD`) and writes the step outputs below
and a job summary itself. In any other orchestrator, set `PPDF_RESULT_PATH` to a file name: the CLI writes the
command result there as JSON, with `Command`, `ExitCode` and, depending on the command, `PlanPath`, `PlanHash`,
`ApprovalTier`, `ApprovalEnvironment`, `Summary`, `ReportPath`, `ReportHash`, `Pass`, `ResultPath`,
`EvidencePath`, `Refused`, `Error` or `Errors`. "Has changes" and "blocked" follow from the exit code (2 and 3).

| Output | Produced by | Meaning |
|---|---|---|
| `plan_path`, `plan_hash` | plan, promote, drift, rollback | Plan document and its SHA-256. |
| `has_changes`, `blocked` | plan, promote, drift, rollback | `true`/`false`. |
| `approval_tier`, `approval_environment` | plan, promote, drift, rollback | Required tier and gate name. |
| `workloads` | plan, promote, drift, rollback | Comma-separated workloads with pending actions. |
| `drift_detected` | drift | `true` when the tenant differs from config. |
| `sim_report_path`, `sim_report_hash`, `sim_pass` | simulation-report, promote | Simulation report and whether every artifact passed. |
| `apply_result_path`, `evidence_path` | apply | Apply result and the evidence bundle. |
| `ppdf_exit_code` | all | The CLI exit code. |

### What to keep, and pinning

- Keep plan artifacts at least until `maxPlanAgeHours` has passed, and the `evidence/` bundle from every apply
  for as long as your audit policy requires (the examples keep 90 days). Rollback needs the evidence.
- Pin the framework to a release tag or commit SHA, and use the same ref for the reusable workflow, the template
  repository and the framework checkout.
- The setup steps install the tested module versions: `powershell-yaml` `[0.4.7,1.0.0)`,
  `ExchangeOnlineManagement` `[3.8.0,4.0.0)` and `Microsoft.Graph.Authentication` `[2.25.0,3.0.0)`. PowerShell 7.4+
  is required.

---

## GitHub Actions

### Files

| File | Purpose |
|---|---|
| [`.github/workflows/ppdf-plan.yml`](../.github/workflows/ppdf-plan.yml) | Reusable workflow: validate, then `plan`, `promote`, `drift` or `simulation-report` as the reader. Uploads the plan artifact. |
| [`.github/workflows/ppdf-apply.yml`](../.github/workflows/ppdf-apply.yml) | Reusable workflow: runs in the approval environment, downloads the plan and applies it as the deployers. Uploads evidence. |
| [`.github/actions/setup-ppdf`](../.github/actions/setup-ppdf/action.yml) | Composite action: checks PowerShell 7.4+, installs the modules and sets `PPDF_CLI`, `PPDF_MODULE_PATH`, `PPDF_SCHEMA_PATH` and `PPDF_CONFIG_ROOT`. |
| [`pipelines/github/workflows/purview-pr.yml`](../pipelines/github/workflows/purview-pr.yml) | Example caller: offline validation for every PR, plus a read-only prod plan posted as a PR comment. |
| [`pipelines/github/workflows/purview-deploy.yml`](../pipelines/github/workflows/purview-deploy.yml) | Example caller: on merge, dev then test (plan → approval → apply); manual runs for any environment and command, including `promote`. |
| [`pipelines/github/workflows/purview-scheduled.yml`](../pipelines/github/workflows/purview-scheduled.yml) | Example caller: daily simulation report and drift check; opens an issue labelled `ppdf-drift`. |

### Setup

1. **Repositories.** Keep configuration in its own repository (`config/environments`, `config/artifacts`). Copy
   the three example callers into its `.github/workflows/` and pin `uses:` and `framework-ref` to a release.
2. **Identities.** Create them with
   [`identities/terraform/examples/github`](../identities/terraform/examples/github/main.tf) (or
   [`identities/powershell/New-PpdfIdentities.ps1`](../identities/powershell/New-PpdfIdentities.ps1)), then grant
   Purview roles with `Grant-PpdfPurviewRoles.ps1`. Put the client IDs in `spec.identities` of each environment
   file.
3. **GitHub environments.** Create these in the configuration repository:

   | Environment | Identity whose OIDC subject it carries | Protection |
   |---|---|---|
   | `<env>-read` | reader | Deployment branch policy (for example `main`); no reviewers. |
   | `<env>-low` | deployers | Branch policy. |
   | `<env>-standard` | deployers | Required reviewers, prevent self-review, branch policy. |
   | `<env>-elevated` | deployers | More (or more senior) required reviewers, prevent self-review, branch policy. |
   | `<env>-critical` | deployers | The most senior reviewers, prevent self-review, branch policy, optional wait timer. |

   The names must match `approvals.pattern` in the environment file. `ring-pilot` shares the prod tenant, so the
   example uses `prod-read` and `prod-<tier>` for it.
4. **Branch protection.** Require pull request review and the `purview-pr` checks on `main`, and use CODEOWNERS
   for `config/` so the people who own a workload review its artifacts.

### Inputs

`ppdf-plan.yml`:

| Input | Default | Purpose |
|---|---|---|
| `environment` | required | PPDF environment name (`environments/<name>.yml`). |
| `github-environment` | required | The reader's GitHub environment, for example `prod-read`. |
| `command` | `plan` | `plan`, `promote`, `drift`, `simulation-report` or `rollback`. |
| `stage` | `simulate` | For `plan`: `simulate`, `enforce` or `auto`. |
| `rollback-run-id` | `''` | For `rollback`: the run ID of the workflow run whose apply you want to undo. |
| `rollback-artifact` | `''` | For `rollback`: the evidence artifact name (`ppdf-evidence-<env>-<run>-<attempt>`). Empty picks the run's only `ppdf-evidence-<environment>-*` artifact. |
| `config-root` | `config` | Configuration root in the calling repository. |
| `artifacts`, `workloads` | `''` | Optional comma-separated filters. |
| `fail-on-blocked` | `true` | Fail the job on exit 3. Set `false` for report-only jobs. |
| `runner` | `ubuntu-latest` | Runner label. |
| `framework-repository`, `framework-ref` | this repository, `main` | Where to fetch the framework from; pin the ref. |

Outputs: `exit_code`, `plan_hash`, `has_changes`, `blocked`, `approval_tier`, `approval_environment`,
`workloads`, `sim_pass` and `artifact_name`.

The plan job needs `contents: read`, `id-token: write` and `actions: read` (to download another run's evidence
for `rollback`). Every caller must grant all three, as the example callers do.

**Rolling back.** Run `purview-deploy.yml` manually with `command: rollback`, the environment, and the run ID of
the deployment to undo (plus `rollback-artifact` if that run applied more than one environment's evidence
under the same pattern). The plan job downloads the evidence, checks that the applied plan was for the same
environment, and builds `rollback-plan.json`. The rollback plan then goes through the normal `elevated` (or
higher) gate and apply job. Evidence is kept for 90 days in the examples; you can't roll back a run whose
evidence has expired.

`ppdf-apply.yml` takes `environment`, `approval-environment`, `approval-tier`, `plan-artifact` and `plan-hash`
(wire them from the plan outputs, as `purview-deploy.yml` does), plus optional `workloads`, `runner`,
`framework-repository` and `framework-ref`. It outputs `exit_code`. Applies to the same environment are
serialised with a concurrency group.

> In GitHub, one job runs under one environment, so all deployers for that environment trust the same
> `<env>-<tier>` subject, and the engine picks the workload's identity for each group of actions.
> `approvals.pattern` supports only `{env}` and `{tier}`. To give each workload its own approvers, run one
> plan/apply pair per workload (the `workloads` input), pass a per-workload `approval-environment` such as
> `prod-dlp-elevated`, and trust that subject only on the matching deployer app.

---

## Azure DevOps Pipelines

### Files

| File | Purpose |
|---|---|
| [`templates/stages-environment.yml`](../pipelines/azure-devops/templates/stages-environment.yml) | One environment: a plan stage plus one apply stage per approval tier. |
| [`templates/stage-plan.yml`](../pipelines/azure-devops/templates/stage-plan.yml) | Validate, then `plan`/`promote`/`drift`/`simulation-report` as the reader; publishes the plan artifact. |
| [`templates/stage-apply.yml`](../pipelines/azure-devops/templates/stage-apply.yml) | Deployment job against `<prefix>-<tier>`; one apply step per workload, each under its own service connection. |
| [`templates/steps-ppdf.yml`](../pipelines/azure-devops/templates/steps-ppdf.yml) | Runs one CLI command under one service connection (AzureCLI@2 as the token broker). |
| [`templates/steps-setup.yml`](../pipelines/azure-devops/templates/steps-setup.yml) | Checks out config and framework, installs the modules, sets `PPDF_*` variables. |
| [`examples/purview-pr.yml`](../pipelines/azure-devops/examples/purview-pr.yml) | PR validation plus a read-only prod plan. |
| [`examples/azure-pipelines.yml`](../pipelines/azure-devops/examples/azure-pipelines.yml) | Ring rollout on merge (dev, then test) and manual runs for any environment and command. |
| [`examples/purview-scheduled.yml`](../pipelines/azure-devops/examples/purview-scheduled.yml) | Daily simulation report and drift check. |

**Why one apply stage per tier?** Azure DevOps resolves a deployment job's environment when the pipeline is
compiled, before the plan has run. So the template emits an apply stage for every tier, each targeting
`<prefix>-<tier>`, and a condition lets only the stage matching the plan's `approval_tier` run. The others show
as skipped. A later environment depends on all of them and continues unless one failed.

### Setup

1. **Framework repository resource.** Create a read-only GitHub service connection named `github-ppdf` (or
   import the framework into Azure Repos and change the `resources.repositories` entry). Pin `ref` to a release
   tag.
2. **Identities.** Create them with
   [`identities/terraform/examples/azure-devops`](../identities/terraform/examples/azure-devops/main.tf), then grant
   Purview roles with `Grant-PpdfPurviewRoles.ps1`.
3. **Service connections.** One per identity, named `sc-ppdf-<env>-<role>` (`reader`, `classifier`, `dlp`,
   `rbac`, `retention`):
   - Azure Resource Manager, **workload identity federation**, created manually for the existing app registration.
   - No subscription access or Azure RBAC role is needed: the task signs in with `--allow-no-subscriptions` and
     PPDF only uses the federated token.
   - Turn **Grant access permission to all pipelines** off and authorise only the PPDF pipelines.
   - Optionally add an Approvals check to each deployer connection as a second, identity-level gate.
4. **Environments.** Create `<prefix>-low`, `<prefix>-standard`, `<prefix>-elevated` and `<prefix>-critical`
   with **Approvals** checks (approvers must not approve their own runs). Add Business hours, Exclusive lock or
   Required template checks as needed. The prefix must match `approvals.pattern`; the stage refuses to apply
   (exit 3) when the plan expects a different environment.
5. **Pipelines.** Create pipelines from the three examples. For Azure Repos, add `purview-pr.yml` as a build
   validation branch policy on `main`. For GitHub-hosted configuration, keep builds from forks without access to
   secrets.

### Parameters

`stages-environment.yml`:

| Parameter | Default | Purpose |
|---|---|---|
| `id` | required | Stage-safe identifier (letters, digits, underscore), for example `ring_pilot`. Stages are `Plan_<id>` and `Apply_<id>_<tier>`. |
| `environment` | required | PPDF environment name. |
| `approvalEnvironmentPrefix` | required | Prefix of the Azure DevOps environments, for example `prod` → `prod-elevated`. |
| `readerServiceConnection` | required | Reader service connection. |
| `serviceConnections` | required | Map of workload → service connection, in engine order (`classifier`, `dlp`, `rbac`, `retention`). Omit workloads you don't deploy. |
| `command` | `plan` | `plan`, `promote`, `drift`, `simulation-report` or `rollback`. |
| `stage` | `auto` | For `plan`: `simulate`, `enforce` or `auto`. |
| `rollbackRunId` | `''` | For `rollback`: the run (build) ID whose apply you want to undo. |
| `rollbackArtifact` | `''` | For `rollback`: the apply artifact name (`ppdf-apply-<env>-<attempt>`). Empty downloads every `ppdf-apply-<environment>-*` artifact of that run, which must all hold the same plan. |
| `rollbackPipelineId` | `$(System.DefinitionId)` | For `rollback`: the pipeline definition that produced the run. |
| `artifacts`, `workloads` | `''` | Optional comma-separated filters. |
| `tiers` | all four | Tiers to emit apply stages for. |
| `dependsOn` | `[]` | Previous stages (all plan and apply stages of the previous environment). |
| `frameworkRepository` | `ppdf` | Repository resource alias (`self` when config and framework share a repository). |
| `configRoot` | `config` | Configuration root. |
| `pool` | `vmImage: ubuntu-latest` | Agent pool. |

The plan stage's job `Plan` exposes `meta.artifact_name` and `ppdf.plan_hash`, `ppdf.has_changes`,
`ppdf.blocked`, `ppdf.approval_tier`, `ppdf.approval_environment`, `ppdf.workloads`, `ppdf.sim_pass` and
`ppdf.exit_code`. The apply stage fails if a workload in the plan has no service connection mapped.

**Rolling back.** Queue `azure-pipelines.yml` manually with `command: rollback`, the environment and
`rollbackRunId` (runtime parameters can't default to an empty string, so the example uses `none` to mean "not
set"). The plan stage downloads the apply artifact of that run, which holds one `apply-<workload>/` folder per
workload, checks that every apply result belongs to the same plan and environment, and builds
`rollback-plan.json` from all of them. It is then gated and applied like any plan. The pipeline's build service
identity needs read access to the source run's artifacts (the default within one project).

> **Verify in your organisation:** that `DownloadPipelineArtifact@2` with `itemPattern` selects the right
> artifacts when `rollbackArtifact` is empty. If in doubt, pass the artifact name.

> **Verify in your organisation:** that AzureCLI@2 signs in with a workload identity federation connection that
> has no subscription. If it doesn't, scope the connection to an empty resource group with no role assignments.

---

## Terraform

The Terraform adapter runs PPDF from a Terraform module. A `data.external` source runs the plan as the reader
during `terraform plan`, and a `terraform_data` resource keyed on the plan hash runs the apply as the deployers
during `terraform apply`. HCP Terraform's "Confirm & apply" is the human gate, `approved_tier` is raised by pull
request, and each workload gets its own workspace. `terraform destroy` doesn't delete Purview objects.

Full setup and usage: [`pipelines/terraform/README.md`](../pipelines/terraform/README.md).

---

## Building an adapter for another orchestrator

Any system that can run PowerShell 7.4+, hold a job for human approval and pass files between jobs can run PPDF
(for example Jenkins, GitLab CI, Octopus Deploy or a scheduled automation account). The flow is:

```text
job plan   (identity: reader)
    pwsh cli/ppdf.ps1 validate -Environment prod -OutputPath out/validate        # exit 1 => fail
    pwsh cli/ppdf.ps1 plan     -Environment prod -OutputPath out/plan            # PPDF_RESULT_PATH=out/result.json
    if exit 1 or 3: fail;  if exit 0: stop (nothing to do)
    read ApprovalTier, ApprovalEnvironment, PlanHash from out/result.json
    publish out/plan as an artifact; show out/plan/plan.md to approvers

gate       (the approval_environment gate; reviewers read plan.md and the plan hash)

job apply  (identity: workload deployers; credentials only available after the gate)
    download the plan artifact
    pwsh cli/ppdf.ps1 apply -PlanPath plan/plan.json -ExpectedPlanHash <plan_hash> `
                            -ApprovedTier <tier of this gate> -OutputPath out/apply
    publish out/apply (evidence) as a long-lived artifact
```

Checklist:

- [ ] The write identities can't sign in before approval (bind their credentials to the gated job only).
- [ ] The reader is used for plan, report and drift; deployers only for apply.
- [ ] Apply receives the hash that was shown to the approver, never one recomputed in the apply job.
- [ ] `-ApprovedTier` comes from the gate that actually approved the job, not from the plan.
- [ ] There is one gate per tier (or one gate whose reviewers are chosen by tier), with self-approval blocked.
- [ ] Applies to the same environment are serialised.
- [ ] Plans and evidence are retained, and the framework version is pinned.
- [ ] Sign-in works: set `PPDF_FEDERATED_TOKEN` (or `AZURE_FEDERATED_TOKEN_FILE`) to the orchestrator's OIDC token,
      or use a certificate (`PPDF_CERT_*`). See [identities](identities.md).
