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
  display_name         = var.instance_display_name
  shape                 = "VM.Standard.A1.Flex"

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
    # Only auto-assign an ephemeral IPv6 here if we're NOT going to reserve one
    # below — reserving uses a separate oci_core_ipv6 resource instead.
    assign_ipv6ip    = var.enable_ipv6 && !var.reserve_public_ip
  }

  metadata = {
    ssh_authorized_keys = file(local.ssh_public_key_path)
  }

  # Prevents Terraform from destroying/recreating an already-running instance
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

# --- Reserved public IPv4 (stays fixed across stop/start) ---
resource "oci_core_public_ip" "reserved_ipv4" {
  count          = var.reserve_public_ip ? 1 : 0
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"
  display_name   = "${var.instance_display_name}-reserved-ip"
  private_ip_id  = data.oci_core_private_ips.instance_private_ip.private_ips[0].id
}

data "oci_core_private_ips" "instance_private_ip" {
  ip_address = oci_core_instance.this.private_ip
  subnet_id  = oci_core_subnet.this.id
}

# --- Reserved IPv6 (separate resource type — IPv4/IPv6 reservation work differently in OCI) ---
data "oci_core_vnic_attachments" "instance_vnics" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.this.id
}

resource "oci_core_ipv6" "reserved_ipv6" {
  count           = (var.enable_ipv6 && var.reserve_public_ip) ? 1 : 0
  vnic_id         = data.oci_core_vnic_attachments.instance_vnics.vnic_attachments[0].vnic_id
  subnet_id       = oci_core_subnet.this.id
  display_name    = "${var.instance_display_name}-reserved-ipv6"
  lifetime        = "RESERVED"
}