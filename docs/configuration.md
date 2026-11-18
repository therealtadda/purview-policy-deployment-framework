# Configuration reference

PPDF configuration is a folder of YAML (or JSON) files kept in source control. Every pipeline and every command
reads the same folder.

```text
config/                          # the "config root" (-ConfigRoot, $env:PPDF_CONFIG_ROOT, default ./config)
├── environments/
│   ├── dev.yml                  # one file per environment; the file name is the environment name
│   ├── test.yml
│   └── prod.yml
└── artifacts/                   # any folder structure you like; every *.yml/*.yaml/*.json with
    ├── dlp/finance-pci.yml      # apiVersion: ppdf.purview/v1 is an artifact
    ├── retention/…
    ├── rbac/…
    └── classifiers/contoso-project-codes/
        ├── contoso-project-codes.yml
        ├── rule-pack.xml        # companion files are referenced relative to the artifact file
        └── corpus.yml
```

Files under `artifacts/` without `apiVersion: ppdf.purview/v1` are ignored, so you can keep notes or helper
files alongside artifacts. A complete working example is in [`examples/contoso`](../examples/contoso).

Run `Invoke-PpdfValidate` (or `pwsh ./cli/ppdf.ps1 validate`) after every edit. It is offline and catches
schema errors, unresolved variables, guardrail violations and missing companion files.

---

## Environments

An environment is a tenant (or one ring of a tenant) with its own identities, thresholds and approval gates.

```yaml
apiVersion: ppdf.purview/v1
kind: Environment
metadata:
  name: prod                       # must equal the file name (prod.yml)
  description: Contoso production tenant
spec:
  tenant:
    tenantId: 00000000-0000-0000-0000-000000000000
    organization: contoso.onmicrosoft.com   # initial (.onmicrosoft.com) domain
    cloud: Commercial                       # Commercial | GCC | GCCHigh | DoD
  workloads: [dlp, retention, classifier, rbac]   # omit for all
  identities:
    reader:     { clientId: … }    # required: plan, simulation-report, promote, drift, export
    dlp:        { clientId: … }    # one identity per workload (see docs/identities.md)
    retention:  { clientId: … }
    classifier: { clientId: … }
    rbac:       { clientId: … }
  variables:
    financeGroup: finance@contoso.onmicrosoft.com
  ring: { … }                      # optional, single-tenant ring topology
  simulation: { … }
  approvals: { … }
  guardrails: { … }
  allowDestructive: false
```

### `spec.tenant`

| Field | Required | Meaning |
|---|---|---|
| `tenantId` | yes | Entra tenant GUID (or a `${env:NAME}` reference). |
| `organization` | yes | Initial domain, used for Security & Compliance PowerShell sign-in. |
| `cloud` | no | `Commercial` (default), `GCC`, `GCCHigh` or `DoD`. Selects sign-in and service endpoints. |
| `sccTokenScope` | no | Override for the app-only Security & Compliance token scope. Only needed if Microsoft changes it. |

### `spec.workloads`

Which workloads this environment manages: `dlp`, `retention`, `classifier`, `rbac`. Artifacts of other workloads
are skipped for this environment (they are not even validated against its variables). A ring environment usually
manages only the workloads that can be scoped (DLP and retention).

### `spec.identities`

One entry per identity role. Only `reader` is required; add a deployer role for each workload you manage.

| Field | Meaning |
|---|---|
| `clientId` | Application (client) ID of the app registration or agent identity. |
| `authMode` | `federated` (default; OIDC from the pipeline), `managedidentity-fic` (self-hosted runner with a user-assigned managed identity as a federated credential), `certificate`, or `interactive` (local use only). |
| `adoServiceConnectionId` | Azure DevOps only: the service connection to request the OIDC token from. |
| `managedIdentityClientId` | `managedidentity-fic` only: client ID of the user-assigned managed identity on the runner. |
| `certificateThumbprint` / `certificatePath` | `certificate` only. The password comes from `PPDF_CERT_PASSWORD`; never put it in config. |

Which `authMode` to choose, and how to create the identities, is covered in [identities.md](identities.md).

### `spec.variables`

Name/value pairs substituted into artifacts. See [Variables](#variables-and-substitution).

### `spec.ring`

Use rings to roll a change out to a pilot population of a tenant before the whole tenant. A ring is a separate
environment file that points at the same tenant.

```yaml
ring:
  name: pilot
  order: 1
  locationOverrides:
    ExchangeLocation: [ppdf-pilot@contoso.onmicrosoft.com]
    SharePointLocation: [https://contoso.sharepoint.com/sites/ppdf-pilot]
```

When a policy already targets a location listed here, its value is replaced by the override. Policies that
do not target that location are not widened. An artifact can opt out with `metadata.ringOverrides: false`.
At the simulate stage an artifact's own `simulation.scope` takes precedence over the ring overrides.

### `spec.simulation`

| Field | Default | Meaning |
|---|---|---|
| `dlpMode` | `TestWithoutNotifications` | DLP test mode used at the simulate stage. `TestWithNotifications` also shows policy tips to users. |
| `minSoakHours` | none | Minimum time a `mode` simulation must run before it can pass. Use days (72–168 h) in production. |
| `maxReportAgeHours` | 168 | A simulation report older than this cannot be used as promotion evidence. |
| `lookbackDays` | 7 | Activity Explorer look-back window, 1–30 days. |
| `thresholds` | none | Per-kind threshold defaults, e.g. `DlpPolicy: { maxMatchesPerDay: 2000 }`. |

Threshold names and precedence are described in [lifecycle.md](lifecycle.md#thresholds).

### `spec.approvals`

| Field | Default | Meaning |
|---|---|---|
| `pattern` | `{env}-{tier}` | Name of the orchestrator approval gate for a plan. `{env}` is the environment name and `{tier}` the plan's required tier. |
| `environments` | none | Explicit gate name per tier (`low`, `standard`, `elevated`, `critical`); overrides `pattern`. |
| `maxPlanAgeHours` | 24 | Apply refuses plans older than this. Keep it short in production so approvers always see current state. |

`ring-pilot` in the example sets `pattern: "prod-{tier}"` so that the pilot ring is approved by the same people
(and runs with the same identities) as production.

### `spec.guardrails`

| Field | Meaning |
|---|---|
| `entraRoleAllowlist` | Entra role definition IDs that `EntraRoleAssignment` artifacts may assign. Anything else fails validation. **Required** to manage Entra roles. |
| `entraPrincipalAllowlist` | Optional principal object IDs that may receive Entra role assignments. |
| `sensitiveRoleGroupRoles` | Additional Purview roles that make a role-group change `critical`. |

### `spec.allowDestructive`

`false` by default. When an artifact file is deleted from config, the objects it created become *orphans*.
Deleting an orphaned top-level object is blocked unless this is `true`. Even then it needs `critical` approval.
The safer route is to keep the file and set `metadata.ensure: absent`, so the removal is explicit in review.

---

## Artifacts

Every artifact uses the same envelope; `spec` (and `simulation`) is defined per kind.

```yaml
apiVersion: ppdf.purview/v1
kind: DlpPolicy                    # see `Get-PpdfKind` or `ppdf.ps1 kinds`
metadata:
  name: PPDF-Finance-PCI           # the object name in Purview; unique per kind
  description: Block external sharing of payment card numbers
  owner: compliance-engineering@contoso.com
  environments: [test, prod]       # optional: only these environments
  ensure: present                  # present (default) | absent
  adopt: false                     # take ownership of an existing unmanaged object
  riskTier: standard               # minimum approval tier for any change to this artifact
  ringOverrides: true              # apply the environment's ring.locationOverrides
  labels: { costCentre: "1234" }   # free-form, informational
spec:
  …                                # kind-specific; see schemas/kinds/<Kind>.schema.json
simulation:
  skip: false                      # true = promote without simulation (forces critical approval)
  scope: { ExchangeLocation: [pilot@contoso.com] }   # locations used only while simulating
  mode: TestWithNotifications      # DlpPolicy only: overrides spec.simulation.dlpMode
  thresholds: { maxMatchesPerDay: 500 }
```

### Metadata

| Field | Meaning |
|---|---|
| `name` | Object name in Purview, 1–64 characters, no `[ ] < > % &`. Renaming an artifact creates a new object and orphans the old one, so plan renames deliberately. |
| `environments` | Restricts the artifact to the listed environments. Omit to deploy everywhere. |
| `ensure` | `absent` plans deletion of the artifact's top-level object (child rules go with it). Deleting a top-level object always needs `critical` approval. |
| `adopt` | When an object with this name already exists but has no PPDF ownership tag, plan blocks it unless `adopt: true`. Remove the flag after the first successful apply. |
| `riskTier` | Raises (never lowers) the approval tier for every change to this artifact. |

### Kinds (Phase 1)

| Kind | Workload / identity | Example | Notes |
|---|---|---|---|
| `DlpPolicy` | dlp | [finance-pci.yml](../examples/contoso/artifacts/dlp/finance-pci.yml) | Policy plus its rules. `spec.mode` is the *enforced* mode; the simulate stage uses a test mode. |
| `RetentionPolicy` | retention | [teams-chats-3y.yml](../examples/contoso/artifacts/retention/teams-chats-3y.yml) | Policy plus one rule. Preservation Lock needs `spec.acknowledgeIrreversible: true`. |
| `RetentionLabel` | retention | [finance-7y-label.yml](../examples/contoso/artifacts/retention/finance-7y-label.yml) | Some label properties are immutable; changing them is blocked (create a new label). |
| `RetentionLabelPolicy` | retention | [finance-autoapply-policy.yml](../examples/contoso/artifacts/retention/finance-autoapply-policy.yml) | Publishes or auto-applies labels. |
| `SensitiveInfoTypeRulePackage` | classifier | [contoso-project-codes](../examples/contoso/artifacts/classifiers/contoso-project-codes) | `spec.rulePackFile` (XML) and `spec.testCorpusFile`. Bump the RulePack `Version` on every change. |
| `RoleGroup` | rbac | [ppdf-dlp-reviewers.yml](../examples/contoso/artifacts/rbac/ppdf-dlp-reviewers.yml) | Purview role group and members. Roles cannot change in place. |
| `EntraRoleAssignment` | rbac | [compliance-admins-pim.yml](../examples/contoso/artifacts/rbac/compliance-admins-pim.yml) | PIM eligible or active assignment; must be on `guardrails.entraRoleAllowlist`. |

`Get-PpdfKind | Format-Table` prints the same table from the loaded module, including simulation strategy and
whether promotion needs evidence. The JSON Schemas in [`schemas/kinds`](../schemas/kinds) are the authoritative
field reference. Point your editor's YAML extension at them for completion and inline errors.

### SIT test corpus

`SensitiveInfoTypeRulePackage` simulation runs every case in the corpus through `Test-DataClassification` and
computes precision, recall and false positives:

```yaml
cases:
  - name: positive-with-keyword
    text: "Please charge the hours to project code PRJ-2024-00417 before Friday."
    expect: ["Contoso Project Code"]        # entity names (LocalizedStrings Name) that must match
  - name: positive-file
    file: ./corpus/positive-status-report.txt
    expect: ["Contoso Project Code"]
  - name: negative-baseline
    text: "Ordinary text that should not match anything."
    expect: []                               # nothing may match
```

Use synthetic data only. Never commit real sensitive content to the corpus.

---

## Variables and substitution

Any string value in an artifact can contain:

| Syntax | Resolved from |
|---|---|
| `${name}` | `spec.variables.name` of the environment being processed. |
| `${env:NAME}` | The process environment variable `NAME` (for example a pipeline variable). |

If a whole value is a single `${name}` and the variable is a list or mapping, the list or mapping is
substituted (for example `ExchangeLocation: ${complianceAdmins}`). Unresolved references are validation
errors, so a typo cannot reach a tenant. Substitution happens before hashing, so an artifact has a different
hash in each environment and simulation evidence from one environment cannot be reused in another.

---

## Ownership tags

PPDF records ownership as a trailing tag in the object's `Comment` (DLP policies and rules, retention policies,
rules and labels) or `Description` (role groups):

```text
Blocks external sharing of credit card numbers. [ppdf:v1 id=DlpPolicy/PPDF-Finance-PCI sha=1a2b3c4d stage=simulate ts=2025-01-01T00:00:00Z]
```

- `id`: the artifact (`<Kind>/<name>`; shadow simulation copies use `<id>#sim`).
- `sha`: the first 8 characters of the artifact hash that was last applied.
- `stage`: `simulate` or `enforce`.
- `ts`: when it was applied (used to measure soak time).

Do not edit or remove the tag in the portal. Without it PPDF treats the object as unmanaged. An object whose tag
names a different artifact is never modified (the plan is blocked).

SIT rule packages, role-group membership and Entra role assignments have no free-text field to hold a tag. They
are matched by identity (rule-package ID, role group, principal + role + scope), so they are never detected as
orphans. Remove them with `metadata.ensure: absent`.
