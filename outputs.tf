output "instance_public_ip" {
  value = var.reserve_public_ip ? oci_core_public_ip.reserved_ipv4[0].ip_address : oci_core_instance.this.public_ip
}

output "instance_private_ip" {
  value = oci_core_instance.this.private_ip
}

output "instance_public_ipv6" {
  value = (
    !var.enable_ipv6 ? "IPv6 not enabled" :
    var.reserve_public_ip ? oci_core_ipv6.reserved_ipv6[0].ip_address :
    "assigned (ephemeral) — check the instance's VNIC in the console for the address"
  )
}

output "object_storage_namespace" {
  value = data.oci_objectstorage_namespace.this.namespace
}

output "bucket_name" {
  value = oci_objectstorage_bucket.this.name
}

output "state_bucket_name" {
  value = oci_objectstorage_bucket.state.name
}

output "bucket_s3_endpoint" {
  value = "https://${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "bucket_client_user_ocid" {
  value = var.bucket_client_access ? oci_identity_user.bucket_client[0].id : "bucket client access not enabled"
}

output "fqdn" {
  value = (var.vcn_dns_label != "" && var.subnet_dns_label != "") ? "${var.instance_display_name}.${var.subnet_dns_label}.${var.vcn_dns_label}.oraclevcn.com" : "DNS labels not set"
}
