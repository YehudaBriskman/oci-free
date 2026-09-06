# Tracks the newest Ubuntu 24.04 aarch64 image rather than pinning a stale OCID.
# The shape filter is what restricts results to ARM builds.
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "arm" {
  compartment_id      = var.tenancy_ocid
  availability_domain = local.ad
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gbs
    # vpus_per_gb intentionally unset -> Balanced (10), which is the Always Free default.
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = true
    hostname_label   = var.instance_name
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      ts_authkey   = var.tailscale_auth_key
      ts_hostname  = var.tailscale_hostname
      ts_exit_node = var.advertise_exit_node
    }))
  }

  # Enabling the monitoring plugin makes memory utilization visible to OCI.
  # Idle reclamation requires CPU *and* network *and* memory all under 20%,
  # so a reported memory figure above that threshold alone protects the box.
  agent_config {
    is_monitoring_disabled = false
    is_management_disabled = false

    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
  }

  lifecycle {
    # Image updates should not silently destroy and recreate a running node.
    ignore_changes = [source_details[0].source_id]
  }
}
