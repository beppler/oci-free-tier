terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"   # 5.x predates the `lifetime` argument on oci_core_ipv6 (reserved IPv6)
    }
  }
}

locals {
  # pathexpand() resolves ~ to the actual home directory at apply time both on Linux and Windows
  private_key_path = pathexpand(var.private_key_path)
  ssh_public_key_path = pathexpand(var.ssh_public_key_path)
  bucket_client_public_key_path = pathexpand(var.bucket_client_public_key_path)
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = local.private_key_path
  region           = var.region
}
