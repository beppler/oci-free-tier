data "oci_core_images" "ubuntu_aarch64" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name        = var.instance_display_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_aarch64.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = true
    hostname_label   = var.instance_display_name
    # The IPv6 address comes from the reserved oci_core_ipv6 below instead
    assign_ipv6ip = false
  }

  metadata = {
    ssh_authorized_keys = file(local.ssh_public_key_path)
  }

  # Prevents OpenTofu from destroying/recreating an already-running instance
  # over two things that commonly drift without meaning anything changed:
  # - metadata: file()'s exact bytes (e.g. trailing newline) rarely match
  #   what's actually stored, byte-for-byte, on an imported instance
  # - source_details[0].source_id: the image data source always resolves to
  #   the newest matching image, which won't match whatever image OCID the
  #   instance originally booted from
  lifecycle {
    ignore_changes = [
      metadata,
      source_details[0].source_id,
    ]
  }
}

data "oci_core_vnic_attachments" "instance_vnics" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.this.id
}

locals {
  vnic_id = data.oci_core_vnic_attachments.instance_vnics.vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "instance_private_ip" {
  vnic_id = local.vnic_id
}

# --- Reserved public IPv4 (survives instance termination/recreation) ---
resource "oci_core_public_ip" "reserved_ipv4" {
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"
  display_name   = "${var.instance_display_name}-reserved-ip"
  private_ip_id  = data.oci_core_private_ips.instance_private_ip.private_ips[0].id
}

# --- Reserved IPv6 (separate resource type — IPv4/IPv6 reservation work differently in OCI) ---
resource "oci_core_ipv6" "reserved_ipv6" {
  vnic_id      = local.vnic_id
  subnet_id    = oci_core_subnet.this.id
  display_name = "${var.instance_display_name}-reserved-ipv6"
  lifetime     = "RESERVED"
}
