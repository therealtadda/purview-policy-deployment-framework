terraform {
  required_version = ">= 1.9.0" # cross-variable validation
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}
