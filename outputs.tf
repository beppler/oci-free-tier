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

output "fqdn" {
  value = (var.vcn_dns_label != "" && var.subnet_dns_label != "") ? "${var.instance_display_name}.${var.subnet_dns_label}.${var.vcn_dns_label}.oraclevcn.com" : "DNS labels not set"
}
