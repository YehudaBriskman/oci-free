# Infrastructure: what OpenTofu creates

The `*.tf` files at the root describe everything outside the VM. They are
written for [OpenTofu](https://opentofu.org) (Terraform-compatible) with the
`oracle/oci` provider, locked in `.terraform.lock.hcl`.

## Resources

| File | Creates |
|---|---|
| `network.tf` | a VCN, an internet gateway, a route table, a security list and one public subnet |
| `compute.tf` | one Ampere A1 (ARM) instance on the latest Ubuntu 24.04 ARM image, with its boot volume, bootstrapped by `cloud-init.yaml` |
| `outputs.tf` | the instance's public address and shape, the image used, the block storage left in the free allowance, and next steps |
| `variables.tf` | everything above that is a choice: shape size, boot volume size, region, optional public web and rescue SSH |

## Sized to the Always Free envelope

The defaults use the whole free ARM allowance (2 OCPU, 12 GB) and half of the
200 GB free block storage, leaving the rest spare. Always Free resources only
exist in the tenancy's home region.

> **Never upgrade the tenancy to Pay-As-You-Go.** Always Free is a hard billing
> wall: without an explicit upgrade the account cannot be charged, and
> requests beyond the free envelope simply fail.

Oracle reclaims idle Always Free instances when CPU, network **and** memory all
stay under 20% for a week. Memory is the only one of those a normal workload
moves, so keep the instance's resident memory comfortably above that line, and
keep the instance monitoring agent enabled so memory is reported at all.

## The network, closed by default

The security list opens only what is needed:

- the private-network agent's UDP port, so peers connect directly instead of
  through a relay;
- ICMP "fragmentation needed", for path MTU discovery;
- TCP 80 and 443, **only** when public web ingress is switched on;
- TCP 22, **only** from one CIDR, and only when a rescue path is configured.

Normal administration (SSH and the Kubernetes API) goes over a private network
and is never exposed publicly.

Oracle's Ubuntu images also ship a host iptables ruleset that drops nearly
everything regardless of the security list, so both layers have to be opened.
`cloud-init.yaml` takes care of the host side.

## Bootstrap (`cloud-init.yaml`)

On first boot only:

- installs the private-network agent from its vendor's apt repository, at a
  pinned version, with the signing key inline in this repository rather than
  fetched over the same connection as the packages;
- joins the private network, enables IP forwarding and fixes the host firewall;
- installs the host firewall guard (`node/oci-free-guard.sh`), which keeps pods
  away from the instance metadata service and limits what private-network peers
  can open on the node;
- enables unattended security upgrades.

k3s is installed by hand after that, and its kubeconfig merged into the
operator's.

## Running it

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in; it is gitignored
tofu init
tofu plan
tofu apply
```

The credentials it needs (the OCI API key profile, an SSH public key, the
private network's join key) live in gitignored files and are recreated by hand
on a new machine.
