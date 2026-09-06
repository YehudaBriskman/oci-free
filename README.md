# oci-free

Infrastructure for an Oracle Cloud **Always Free** tenancy: one Ampere A1 ARM node
running k3s, in `il-jerusalem-1`.

> **Never upgrade this tenancy to Pay-As-You-Go.** Always Free is a hard billing
> wall — without an explicit upgrade the account cannot be charged, and requests
> that exceed the free envelope simply fail. PAYG removes that protection.

## Free envelope

| Resource | Limit | Used here |
|---|---|---|
| Ampere A1 | 2 OCPU / 12 GB (halved from 4/24 on 2026-06-15) | all of it |
| Block storage | 200 GB total | 100 GB boot, 100 GB spare |
| AMD micro | 2 × E2.1.Micro | unused |
| Egress | 10 TB/month | Tailscale exit node |
| Load balancer | 1 flexible (10 Mbps) | unused — Traefik on the node instead |

Home region is permanent. Always Free resources exist only there.

## Idle reclamation

Oracle reclaims instances where CPU **and** network **and** memory are all under
20% across 7 days. The CPU and network thresholds are unreachable in normal use
(~400 Mbps sustained), so **memory is the only real lever** — keep more than
~2.4 GB resident. The current workload sits around 25%.

`Compute Instance Monitoring` must stay enabled or memory is never reported.
Check the number Oracle actually evaluates:

```sh
oci monitoring metric-data summarize-metrics-data --profile APIKEY \
  --compartment-id "$TENANCY" --namespace oci_computeagent \
  --query-text "MemoryUtilization[1m].mean()" \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

## Layout

```
*.tf                 OpenTofu: VCN, subnet, security list, A1 instance
cloud-init.yaml      Tailscale join, iptables fix, IP forwarding
k8s/                 Manifests + Helm values, applied against context `oci-free`
```

## Access model

| Host | Reachable from | Gate |
|---|---|---|
| `yehudabriskman.com` | public | none (portfolio) |
| `grafana.` | public | GitHub OAuth, single-user allowlist |
| `auth.` | public | oauth2-proxy itself |
| `git.` | tailnet only | Traefik `ipAllowList` on `100.64.0.0/10` |
| `couchdb.` | tailnet only | same, then CouchDB basic auth |

SSH and the Kubernetes API are never exposed publicly; both go over Tailscale.

Forgejo and CouchDB cannot sit behind the OAuth proxy: git can't complete a browser
redirect, and Obsidian LiveSync uses basic auth. Tailnet restriction is the stronger
control anyway — it requires tailnet membership, not merely a GitHub account.

## Gotchas paid for the hard way

- **Oracle's Ubuntu images ship an iptables ruleset** that drops nearly everything
  regardless of VCN security lists. Both layers must be opened. See
  `/usr/local/sbin/oci-open-*.sh` on the node.
- **Traefik's redirect key is `ports.web.http.redirections.entryPoint`.** Omitting
  the `http` level fails silently: values apply, no argument is emitted.
- **`externalTrafficPolicy: Local` is required for any IP allowlist.** The default
  (`Cluster`) SNATs the source address, so every request looks internal and the
  allowlist blocks everyone including you.
- **oauth2-proxy's `cookie-secret` is measured as a string**, not decoded bytes —
  `openssl rand -base64 32` yields 44 chars and is rejected. Use `rand -hex 16`.
- **k3s has no standalone scheduler/controller-manager/etcd metrics endpoints**, so
  those kube-prometheus-stack scrape jobs are disabled to avoid permanent
  `TargetDown` alerts.

## Portfolio images

Built **natively on the ARM node** and imported straight into k3s containerd —
there is no registry, so `imagePullPolicy: Never` is required or kubelet will try
Docker Hub and fail.

```sh
tar czf - -C ~/projects/personal/portfolio_site --exclude=node_modules --exclude=dist \
  --exclude=.git --exclude=.env glassglow-folio-space backend \
  | ssh ubuntu@100.79.242.82 'rm -rf ~/portfolio && mkdir -p ~/portfolio && tar xzf - -C ~/portfolio'
ssh ubuntu@100.79.242.82 'cd ~/portfolio &&
  sudo docker build -t portfolio-web:latest ./glassglow-folio-space &&
  sudo docker build -t portfolio-api:latest ./backend &&
  for i in portfolio-web portfolio-api; do
    sudo docker save $i:latest | sudo k3s ctr -n k8s.io images import -; done'
kubectl -n prod rollout restart deploy/web deploy/api
```

Source is shipped over SSH rather than cloned: the node cannot reach
`git.yehudabriskman.com`, because traffic to its own tailnet IP does not present a
`100.64.0.0/10` source address and the allowlist rejects it. The same constraint
blocks CI from cloning — unsolved, and the reason builds are still manual.

`kubectl create secret --from-env-file` does **not** strip quotes the way `dotenv`
does, so `CONTACT_TO="a@b.com"` arrives including the quote characters and fails
validation. Normalise before creating the secret.

The frontend's `nginx.conf` proxies `/api/` to `http://api:5000`, so the backend
Service must be named exactly `api` in the same namespace.

## Rebuild

```sh
tofu init && tofu apply          # instance + network
kubectl apply -f k8s/            # after k3s install and kubeconfig merge
```

Secrets (`terraform.tfvars`, `.cf-token`, `.github-oauth`) are gitignored and must
be recreated by hand.
