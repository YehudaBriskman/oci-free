terraform {
  required_version = ">= 1.6.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}

# Uses the permanent API-key profile in ~/.oci/config (not the expiring session token).
provider "oci" {
  config_file_profile = var.oci_profile
  region              = var.region
}
