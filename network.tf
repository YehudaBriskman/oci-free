data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  ad = data.oci_identity_availability_domains.ads.availability_domains[0].name
}

# Always Free allows up to 2 VCNs.
resource "oci_core_vcn" "vcn" {
  compartment_id = var.tenancy_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "${var.instance_name}-vcn"
  dns_label      = "freevcn"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "${var.instance_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "${var.instance_name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "sl" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "${var.instance_name}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Tailscale's WireGuard listener. Needed for direct (non-relayed) connections;
  # without it traffic still works but is DERP-relayed and slower.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "17" # UDP
    udp_options {
      min = 41641
      max = 41641
    }
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1" # ICMP - path MTU discovery
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Public web ingress for Traefik + ACME HTTP-01.
  dynamic "ingress_security_rules" {
    for_each = var.expose_web ? [80, 443] : []
    content {
      source   = "0.0.0.0/0"
      protocol = "6" # TCP
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # Rescue SSH. Created only when ssh_allowed_cidr is non-null.
  dynamic "ingress_security_rules" {
    for_each = var.ssh_allowed_cidr == null ? [] : [var.ssh_allowed_cidr]
    content {
      source   = ingress_security_rules.value
      protocol = "6" # TCP
      tcp_options {
        min = 22
        max = 22
      }
    }
  }
}

resource "oci_core_subnet" "subnet" {
  compartment_id             = var.tenancy_ocid
  vcn_id                     = oci_core_vcn.vcn.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "${var.instance_name}-public-subnet"
  dns_label                  = "pub"
  route_table_id             = oci_core_route_table.rt.id
  security_list_ids          = [oci_core_security_list.sl.id]
  prohibit_public_ip_on_vnic = false
}
