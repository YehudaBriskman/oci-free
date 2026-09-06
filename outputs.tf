output "public_ip" {
  value = oci_core_instance.arm.public_ip
}

output "tailscale_hostname" {
  value = var.tailscale_hostname
}

output "shape" {
  value = "${oci_core_instance.arm.shape} ${var.ocpus} OCPU / ${var.memory_gbs} GB"
}

output "image_used" {
  value = data.oci_core_images.ubuntu_arm.images[0].display_name
}

output "block_storage_remaining_gb" {
  description = "Free tier ceiling is 200 GB across all volumes."
  value       = 200 - var.boot_volume_gbs
}

output "next_steps" {
  value = <<-EOT
    kubectl --context=oci-free get pods -A
    ssh ubuntu@100.79.242.82              # Tailscale SSH, keyless, no public port
    # Public: 80/443 open for Traefik + ACME. 22 and 6443 are tailnet-only.
    # Pending: point an A record at ${oci_core_instance.arm.public_ip}, then apply the ClusterIssuer.
  EOT
}
