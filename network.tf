resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/24"
  display_name   = "vcn-free-public"
  dns_label      = "vcnfree"
  is_ipv6enabled = true
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${oci_core_vcn.this.display_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${oci_core_vcn.this.display_name}-rt"

  dynamic "route_rules" {
    for_each = ["0.0.0.0/0", "::/0"]
    content {
      destination       = route_rules.value
      network_entity_id = oci_core_internet_gateway.this.id
    }
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${oci_core_vcn.this.display_name}-seclist"

  dynamic "egress_security_rules" {
    for_each = ["0.0.0.0/0", "::/0"]
    content {
      destination = egress_security_rules.value
      protocol    = "all"
    }
  }

  # TCP ports: SSH, HTTP, HTTPS - IPv4 and IPv6
  dynamic "ingress_security_rules" {
    for_each = setproduct(["0.0.0.0/0", "::/0"], [22, 80, 443])
    content {
      source   = ingress_security_rules.value[0]
      protocol = "6"
      tcp_options {
        min = ingress_security_rules.value[1]
        max = ingress_security_rules.value[1]
      }
    }
  }

  # ICMP echo request (ping) - IPv4
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 8
    }
  }

  # ICMPv6 echo request (ping) - IPv6
  ingress_security_rules {
    source   = "::/0"
    protocol = "58"
    icmp_options {
      type = 128
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.this.id
  cidr_block        = oci_core_vcn.this.cidr_block
  ipv6cidr_block    = cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 0)
  display_name      = "subnet-free-public"
  dns_label         = "subnetfree"
  route_table_id    = oci_core_route_table.this.id
  security_list_ids = [oci_core_security_list.this.id]
}
