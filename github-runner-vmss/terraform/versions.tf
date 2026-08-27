terraform {
  required_version = ">= 1.7.0"

  # Values supplied via -backend-config flags in the pipeline (terraform-deploy.yml)
  # rather than hardcoded here, so this same config works across environments.
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Align this with whatever provider block your existing repo already uses -
# left out here since it's almost certainly defined elsewhere in your module
# tree (backend config, subscription_id, feature flags, etc.)
# provider "azurerm" {
#   features {}
# }
