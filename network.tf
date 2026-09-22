resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_block     = var.vcn_cidr
  display_name   = var.vcn_name
  dns_label      = var.vcn_dns_label != "" ? var.vcn_dns_label : null
  is_ipv6enabled = var.enable_ipv6
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination       = "::/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_internet_gateway.this.id
    }
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-seclist"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  dynamic "egress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination      = "::/0"
      destination_type = "CIDR_BLOCK"
      protocol         = "all"
    }
  }

  # TCP ports: SSH, HTTP, HTTPS - IPv4
  dynamic "ingress_security_rules" {
    for_each = { ssh = 22, http = 80, https = 443 }
    content {
      source   = "0.0.0.0/0"
      protocol = "6"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # ICMP (ping) - IPv4
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 8
    }
  }

  # Same set again for IPv6, only if enabled
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? { ssh = 22, http = 80, https = 443 } : {}
    content {
      source      = "::/0"
      source_type = "CIDR_BLOCK"
      protocol    = "6"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      source      = "::/0"
      source_type = "CIDR_BLOCK"
      protocol    = "58"
      icmp_options {
        type = 128
      }
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.vcn_cidr
  ipv6cidr_block              = var.enable_ipv6 ? cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 0) : null
  display_name                = var.subnet_name
  dns_label                   = var.subnet_dns_label != "" ? var.subnet_dns_label : null
  route_table_id               = oci_core_route_table.this.id
  security_list_ids            = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic   = false
}
