output "instance_public_ip" {
  value = oci_core_public_ip.reserved_ipv4.ip_address
}

output "instance_private_ip" {
  value = oci_core_instance.this.private_ip
}

output "instance_public_ipv6" {
  value = oci_core_ipv6.reserved_ipv6.ip_address
}

output "fqdn" {
  value = "${var.instance_display_name}.${oci_core_subnet.this.dns_label}.${oci_core_vcn.this.dns_label}.oraclevcn.com"
}
