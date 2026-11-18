variable "framework_path" {
  description = "Path to a checkout of the PPDF framework (contains cli/ppdf.ps1 and src/PurviewIaC). Pin it to a release."
  type        = string
}

variable "config_root" {
  description = "Path to the configuration root (contains environments/ and artifacts/)."
  type        = string
}

variable "environment" {
  description = "PPDF environment name (environments/<name>.yml)."
  type        = string
}

variable "command" {
  description = "plan: converge to the configured stage. promote: move simulated artifacts to enforcement (requires passing simulation evidence)."
  type        = string
  default     = "plan"
  validation {
    condition     = contains(["plan", "promote"], var.command)
    error_message = "command must be plan or promote."
  }
}

variable "stage" {
  description = "Stage for command = plan: simulate, enforce, or auto (each artifact's configured stage)."
  type        = string
  default     = "auto"
  validation {
    condition     = contains(["simulate", "enforce", "auto"], var.stage)
    error_message = "stage must be simulate, enforce or auto."
  }
}

variable "artifacts" {
  description = "Optional artifact names to scope the run to."
  type        = list(string)
  default     = []
}

variable "workloads" {
  description = "Optional workloads to scope the run to (classifier, dlp, rbac, retention)."
  type        = list(string)
  default     = []
}

variable "approved_tier" {
  description = "Highest PPDF approval tier this workspace may apply. Plans needing a higher tier fail at plan time."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["low", "standard", "elevated", "critical"], var.approved_tier)
    error_message = "approved_tier must be low, standard, elevated or critical."
  }
}

variable "apply_enabled" {
  description = "Set false for plan-only workspaces (for example speculative PR plans or drift checks)."
  type        = bool
  default     = true
}

variable "output_path" {
  description = "Where plan, apply results and evidence are written. Defaults to <root>/.ppdf/<environment>."
  type        = string
  default     = null
}

variable "pwsh" {
  description = "PowerShell 7.4+ executable."
  type        = string
  default     = "pwsh"
}
