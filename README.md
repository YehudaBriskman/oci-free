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

Built in the site repository's CI on every push to `main`, published to GHCR
multi-arch, and rolled out here by the same pipeline:

```
push to main ──▶ build + test ──▶ ghcr.io/…/{web,api}:<sha> ──▶ kubectl set image
                                                                      │
                                                 rollout status ──▶ curl the site
                                                                      │
                                                        not 200? ──▶ rollout undo
```

The tag is a commit sha, not `:latest`, so a rollout either lands a specific
build or fails. The API server stays off the internet; the runner joins the
tailnet for the length of the job with an ephemeral node.

### What this replaced, and why it had to

`deploy-portfolio.sh` rsynced a laptop's **working directory** to the node,
built there and imported into containerd — which is why the deployments pinned
`imagePullPolicy: Never`. Two things were wrong with it. The live site could be
running code that was never committed, and for six weeks it was. And it had
stopped working altogether: the script still synced a frontend directory that
had been renamed from `glassglow-folio-space` to `web`, so rsync failed on a
path that no longer existed, `set -e` aborted the run before anything was
built, and the site stayed six weeks old with nothing reporting it.

The script is still here, with the path fixed, for when CI cannot reach the
tailnet. It still ships a working directory, which is why it is the fallback
rather than the route.

The old note here said CI could not clone the repository — the node cannot
reach `git.yehudabriskman.com`, because traffic to its own tailnet IP does not
present a `100.64.0.0/10` source address and the allowlist rejects it. That is
still true and no longer matters: nothing is built on the node, so nothing
needs to clone anything there.

### One-time setup

Three secrets in the **site** repository, one in the cluster.

1. **`TS_OAUTH_CLIENT_ID`** / **`TS_OAUTH_SECRET`** — a Tailscale OAuth client
   with the `auth_keys` scope, plus an ACL grant letting `tag:ci` reach this
   node.
2. **`KUBECONFIG_B64`** — `base64 -w0 < kubeconfig`. Use a ServiceAccount
   scoped to `get`/`patch` on the two deployments in `prod`, not the
   cluster-admin kubeconfig: a rollout needs nothing more, and this credential
   lives in someone else's storage.
3. **`ghcr-pull`** in the cluster, because the packages are private:

   ```sh
   kubectl -n prod create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io --docker-username=<github-user> \
     --docker-password=<PAT with read:packages>
   ```

A `production` environment in the site repository is where a required reviewer
goes, if a human step before a live rollout is wanted.

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
