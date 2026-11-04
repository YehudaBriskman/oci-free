#!/usr/bin/env bash
#
# Host firewall guard for the OCI node (#18). Idempotent: rebuilds one chain,
# OCI-FREE-GUARD, hooked first into mangle PREROUTING, for IPv4 and IPv6.
#
# Why mangle PREROUTING and not filter INPUT: tailscaled re-inserts its own
# `ts-input` chain at the top of INPUT on every start, and that chain accepts
# everything from tailscale0; k3s/kube-router keep reordering filter too.
# Neither touches mangle PREROUTING, so rules here keep their order. They only
# DROP, and only NEW connections, so nothing already open is cut.
#
#  1. Pods may not reach the instance metadata service (169.254.169.254).
#     DNS (53) to the same address is allowed: it is also the VCN resolver.
#     It serves this instance's user_data, which carried the Tailscale auth
#     key, for the life of the instance. hostNetwork pods use the host's own
#     stack (OUTPUT), so they are not covered; they are privileged anyway.
#  2. Tailnet peers may open only ssh (22), the edge (80, 443) and the API
#     server (6443) on this host. Measured 2026-11-04: those are the only ports
#     anything on the tailnet uses. kubelet (10250), node_exporter (9100),
#     rpcbind (111) and NodePorts were open to every tailnet device.
#     `--dst-type LOCAL` limits this to traffic FOR the node, so exit-node
#     traffic passing through is untouched.
#
# Installed by cloud-init (new nodes) as /usr/local/sbin/oci-free-guard plus
# oci-free-guard.service. On the running node: see README "Host firewall".
set -euo pipefail
POD_CIDR=${POD_CIDR:-10.42.0.0/16}
TAILNET_TCP=${TAILNET_TCP:-22,80,443,6443}

build() {  # build <iptables|ip6tables>
  local t=$1
  $t -t mangle -N OCI-FREE-GUARD 2>/dev/null || $t -t mangle -F OCI-FREE-GUARD
  if [ "$t" = iptables ]; then
    # Port 53 first: on OCI 169.254.169.254 is ALSO the VCN DNS resolver, and
    # CoreDNS forwards every external name there. Dropping it whole broke all
    # external DNS in pods (Alertmanager could not resolve smtp.gmail.com).
    # Metadata is HTTP on 80, which stays dropped.
    local p
    for p in udp tcp; do
      $t -t mangle -A OCI-FREE-GUARD -s "$POD_CIDR" -d 169.254.169.254/32 -p "$p" --dport 53 -j RETURN
    done
    $t -t mangle -A OCI-FREE-GUARD -s "$POD_CIDR" -d 169.254.169.254/32 -j DROP
  fi
  local new=(-i tailscale0 -m addrtype --dst-type LOCAL -m conntrack --ctstate NEW)
  $t -t mangle -A OCI-FREE-GUARD "${new[@]}" -p tcp -m multiport --dports "$TAILNET_TCP" -j RETURN
  if [ "$t" = iptables ]; then
    $t -t mangle -A OCI-FREE-GUARD "${new[@]}" -p icmp -j RETURN
  else
    $t -t mangle -A OCI-FREE-GUARD "${new[@]}" -p ipv6-icmp -j RETURN
  fi
  $t -t mangle -A OCI-FREE-GUARD "${new[@]}" -j DROP
  $t -t mangle -C PREROUTING -j OCI-FREE-GUARD 2>/dev/null || $t -t mangle -I PREROUTING 1 -j OCI-FREE-GUARD
}

case "${1:-apply}" in
  apply)  build iptables; build ip6tables ;;
  remove) for t in iptables ip6tables; do
            $t -t mangle -D PREROUTING -j OCI-FREE-GUARD 2>/dev/null || true
            $t -t mangle -F OCI-FREE-GUARD 2>/dev/null || true
            $t -t mangle -X OCI-FREE-GUARD 2>/dev/null || true
          done ;;
  *) echo "usage: $0 [apply|remove]" >&2; exit 2 ;;
esac
