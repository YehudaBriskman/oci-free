variable "oci_profile" {
  description = "Profile name in ~/.oci/config to authenticate with."
  type        = string
  default     = "APIKEY"
}

variable "region" {
  description = "Home region. Always Free resources only exist here, and home region is effectively permanent."
  type        = string
  default     = "il-jerusalem-1"
}

variable "tenancy_ocid" {
  description = "Tenancy OCID; also used as the root compartment."
  type        = string
}

variable "instance_name" {
  type    = string
  default = "free-arm"
}

# --- Always Free envelope. Exceeding any of these makes apply FAIL on a
# --- non-upgraded account rather than incur charges. Do not raise them.
variable "ocpus" {
  description = "Free allowance is 2 OCPU tenancy-wide (halved from 4 on 2026-06-15)."
  type        = number
  default     = 2
}

variable "memory_gbs" {
  description = "Free allowance is 12 GB tenancy-wide."
  type        = number
  default     = 12
}

variable "boot_volume_gbs" {
  description = "Free block storage is 200 GB total across ALL volumes. 100 here leaves 100 spare."
  type        = number
  default     = 100
}

variable "ssh_public_key" {
  description = "Public key injected for the 'ubuntu' user. Rescue path only; normal access is Tailscale SSH."
  type        = string
}

variable "ssh_allowed_cidr" {
  description = <<-EOT
    CIDR permitted to reach port 22 from the public internet, as a lockout rescue path.
    Set to null once Tailscale is confirmed working to close public SSH entirely.
    Your IP changes -- update or set to null accordingly.
  EOT
  type        = string
  default     = null
}

variable "tailscale_auth_key" {
  description = "Reusable Tailscale auth key. Set in terraform.tfvars (gitignored). Never commit."
  type        = string
  sensitive   = true
}

variable "tailscale_hostname" {
  type    = string
  default = "oci-free-arm"
}

variable "advertise_exit_node" {
  description = "Offer this box as a Tailscale exit node (10 TB/mo free egress)."
  type        = bool
  default     = true
}

variable "expose_web" {
  description = <<-EOT
    Open 80/443 to the internet for Traefik ingress and Let's Encrypt HTTP-01 challenges.
    Port 80 cannot be dropped once TLS works: HTTP-01 renewal requires it every 60 days.
  EOT
  type        = bool
  default     = false
}
