output "instance_public_ip" {
  value = oci_core_public_ip.reserved_ipv4.ip_address
}

output "instance_private_ip" {
  value = oci_core_instance.this.private_ip
}

output "instance_public_ipv6" {
  value = oci_core_ipv6.reserved_ipv6.ip_address
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
  value = "${var.instance_display_name}.${oci_core_subnet.this.dns_label}.${oci_core_vcn.this.dns_label}.oraclevcn.com"
}
