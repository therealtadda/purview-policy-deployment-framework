# Terraform adapter for PPDF.
#
#   terraform plan  -> data.external.ppdf runs `ppdf plan|promote` with the READER identity and returns the plan hash,
#                      approval tier and the plan document itself (base64) - all part of the Terraform plan.
#   human approval  -> HCP Terraform "Confirm & apply" (manual apply workspace), or the CLI prompt / saved-plan review.
#   terraform apply -> terraform_data.apply runs `ppdf apply` with the DEPLOYER identities, writing the byte-identical
#                      plan document that was approved and passing its hash, so nothing unreviewed can be applied.
#
# Purview objects are not Terraform resources: PPDF owns diffing and state (the tenant is the state). Removing an
# object is done with `ensure: absent` in config, never with `terraform destroy` (which only forgets the apply record).

locals {
  cli         = "${var.framework_path}/cli/ppdf.ps1"
  output_path = coalesce(var.output_path, "${path.root}/.ppdf/${var.environment}")
  tier_rank   = { low = 1, standard = 2, elevated = 3, critical = 4 }

  r           = data.external.ppdf.result
  has_changes = local.r.has_changes == "true"

  # Split the base64 plan across environment variables (Windows caps a single variable at 32,767 characters).
  chunk_size = 30000
  plan_chunks = {
    for i in range(ceil(length(local.r.plan_b64) / local.chunk_size)) :
    format("PPDF_TF_PLAN_B64_%04d", i) => substr(local.r.plan_b64, i * local.chunk_size, local.chunk_size)
  }
}

data "external" "ppdf" {
  program = [var.pwsh, "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/ppdf-tf-plan.ps1"]
  query = {
    cli         = local.cli
    command     = var.command
    environment = var.environment
    stage       = var.stage
    config_root = var.config_root
    output_path = local.output_path
    artifacts   = join(",", var.artifacts)
    workloads   = join(",", var.workloads)
  }
}

resource "terraform_data" "apply" {
  count = var.apply_enabled ? 1 : 0

  # Re-run whenever the approved plan changes; settles to "in-sync" once the tenant matches config.
  triggers_replace = local.has_changes ? local.r.plan_hash : "in-sync"

  # Deployment record kept in state (no plan content, no secrets).
  input = {
    environment          = var.environment
    command              = var.command
    plan_hash            = local.r.plan_hash
    approval_tier        = local.r.approval_tier
    approval_environment = local.r.approval_environment
    workloads            = local.r.workloads
    summary              = local.r.summary
  }

  lifecycle {
    precondition {
      condition     = local.r.blocked != "true"
      error_message = "The PPDF plan contains blocked actions (see ${local.output_path}/${var.command}.md). Fix the configuration or the tenant before applying."
    }
    precondition {
      condition     = !local.has_changes || local.tier_rank[local.r.approval_tier] <= local.tier_rank[var.approved_tier]
      error_message = "The PPDF plan requires '${local.r.approval_tier}' approval but this workspace is limited to '${var.approved_tier}'. Raise approved_tier through a reviewed change (and the matching workspace approvers) to proceed."
    }
  }

  provisioner "local-exec" {
    interpreter = [var.pwsh, "-NoProfile", "-NonInteractive", "-File"]
    command     = "${path.module}/scripts/ppdf-tf-apply.ps1"
    environment = merge(local.plan_chunks, {
      PPDF_TF_CLI           = local.cli
      PPDF_TF_HAS_CHANGES   = local.r.has_changes
      PPDF_TF_PLAN_HASH     = local.r.plan_hash
      PPDF_TF_APPROVED_TIER = var.approved_tier
      PPDF_TF_OUTPUT_PATH   = "${local.output_path}/apply"
      PPDF_TF_WORKLOADS     = join(",", var.workloads)
    })
  }
}
