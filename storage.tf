data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

locals {
  object_storage_quota_bytes = var.object_storage_quota_gb * 1024 * 1024 * 1024
}

resource "oci_objectstorage_bucket" "this" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = var.bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  # Keep off: previous object versions count toward the 20 GB Always Free limit
  versioning     = "Disabled"
}

# --- Remote Terraform state (see README section 15). Versioning is on here
# because state files are a few KB each, and old versions are what you roll
# back to if a state write goes wrong. ---
resource "oci_objectstorage_bucket" "state" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = var.state_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"
}

# --- Hard cap: the 20 GB is a usage limit, not an allocation — anything
# stored past it is billed. This quota makes writes fail at the limit instead.
# Quota policies must live in the root compartment and need tenancy admin. ---
resource "oci_limits_quota" "object_storage" {
  count          = var.enforce_object_storage_quota ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "object-storage-free-tier"
  description    = "Caps Object Storage at the Always Free allowance"
  statements = [
    "set object-storage quota storage-bytes to ${local.object_storage_quota_bytes} in tenancy",
  ]
}

# --- Instance principal: lets the VM use the bucket without API keys on it ---
resource "oci_identity_dynamic_group" "vm" {
  count          = var.bucket_vm_access ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${var.instance_display_name}-dg"
  description    = "The ${var.instance_display_name} instance, for instance-principal auth"
  matching_rule  = "ALL {instance.id = '${oci_core_instance.this.id}'}"
}

resource "oci_identity_policy" "vm_bucket" {
  count          = var.bucket_vm_access ? 1 : 0
  compartment_id = var.compartment_id
  name           = "${var.instance_display_name}-bucket-access"
  description    = "Lets ${var.instance_display_name} read/write objects in ${var.bucket_name}"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.vm[0].name} to read buckets in compartment id ${var.compartment_id} where target.bucket.name = '${var.bucket_name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.vm[0].name} to manage objects in compartment id ${var.compartment_id} where target.bucket.name = '${var.bucket_name}'",
  ]
}

# --- Dedicated user for other clients (CLI/SDK/rclone on other machines) ---
# Terraform only uploads the public key; the private key stays on the client, so
# no secret lands in state. S3-only tools get a Customer Secret Key created by
# hand in the console for this same user — the policy below already covers it.
resource "oci_identity_user" "bucket_client" {
  count          = var.bucket_client_access ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = var.bucket_client_user_name
  description    = "API-only user for clients of the ${var.bucket_name} bucket"
  email          = var.bucket_client_email
}

# API keys and S3 secret keys only — no console login, auth tokens, or SMTP
resource "oci_identity_user_capabilities_management" "bucket_client" {
  count                        = var.bucket_client_access ? 1 : 0
  user_id                      = oci_identity_user.bucket_client[0].id
  can_use_api_keys             = true
  can_use_customer_secret_keys = true
  can_use_console_password     = false
  can_use_auth_tokens          = false
  can_use_smtp_credentials     = false
}

resource "oci_identity_group" "bucket_client" {
  count          = var.bucket_client_access ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${var.bucket_client_user_name}-group"
  description    = "Clients of the ${var.bucket_name} bucket"
}

resource "oci_identity_user_group_membership" "bucket_client" {
  count    = var.bucket_client_access ? 1 : 0
  group_id = oci_identity_group.bucket_client[0].id
  user_id  = oci_identity_user.bucket_client[0].id
}

resource "oci_identity_api_key" "bucket_client" {
  count     = var.bucket_client_access ? 1 : 0
  user_id   = oci_identity_user.bucket_client[0].id
  key_value = file(local.bucket_client_public_key_path)
}

resource "oci_identity_policy" "bucket_client" {
  count          = var.bucket_client_access ? 1 : 0
  compartment_id = var.compartment_id
  name           = "${var.bucket_client_user_name}-bucket-access"
  description    = "Lets ${var.bucket_client_user_name} read/write objects in ${var.bucket_name}"
  statements = [
    "Allow group ${oci_identity_group.bucket_client[0].name} to read buckets in compartment id ${var.compartment_id} where target.bucket.name = '${var.bucket_name}'",
    "Allow group ${oci_identity_group.bucket_client[0].name} to manage objects in compartment id ${var.compartment_id} where target.bucket.name = '${var.bucket_name}'",
  ]
}
