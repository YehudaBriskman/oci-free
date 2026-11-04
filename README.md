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
| `preprod.` | tailnet only | same, plus `X-Robots-Tag: noindex` |

SSH and the Kubernetes API are never exposed publicly; both go over Tailscale.

Forgejo and CouchDB cannot sit behind the OAuth proxy: git can't complete a browser
redirect, and Obsidian LiveSync uses basic auth. Tailnet restriction is the stronger
control anyway — it requires tailnet membership, not merely a GitHub account.

`preprod.` is tailnet-only for a different reason: not that the OAuth proxy
cannot gate it, but that an unreleased build of the site has no audience on the
internet. The cost of getting that wrong is not only who reads it — a second
public host serving the same pages is a duplicate-content problem the real site
inherits, and an unreleased draft that gets indexed is a URL somebody has to go
and retract. The `noindex` header is belt and braces behind the allowlist, for
the day the host is opened up and nobody remembers to add it. It is a response
header rather than a `robots.txt`, deliberately: the static `robots.txt` the
frontend ships says `Allow: /`, and a crawler must be allowed to fetch a page
in order to be told not to index it.

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
push to main ──▶ build + test ──▶ ghcr.io/…:<sha> ──▶ set image ──▶ ns preprod
push a tag   ──▶ build + test ──▶ ghcr.io/…:<sha> ──▶ set image ──▶ ns prod
                                                            │
                                       rollout status ──▶ curl that environment
                                                            │
                                              not 200? ──▶ rollout undo
```

What rolls out is a digest (`<app>@sha256:…`) from the release manifest CI
records in GHCR, so a rollout either lands a specific build or fails. The API server stays off the internet; the runner joins the
tailnet for the length of the job with an ephemeral node.

**CI owns the image; the manifests do not name one (#25).** `web` and `api`
in `k8s/portfolio.yaml` and `k8s/portfolio-preprod.yaml` have no `image:`
field, so `kubectl apply -f` of either one updates everything else and leaves
the running digest alone. Until 2026-11-04 they said `:latest`, and an apply
of the preprod manifest put the last release back over CI's `main` digest.

A Deployment cannot be created without an image, so the first apply into a
namespace, and the one-time migration of a Deployment last applied from the
old manifest, go through the script (it refuses any cluster without the
`free-arm` node):

```sh
./k8s/portfolio-apply.sh prod       # or preprod; safe to re-run
```

It creates a missing Deployment at `:latest` and lets CI's next deploy pin it.
`:latest` means the last *release* and nothing else, and moves only after a
passing prod deploy; preprod writes no tag at all.

### Preprod

`preprod.yehudabriskman.com` is the same two Deployments in their own namespace
on their own tailnet-only host, carrying whatever is on `main`. It exists
because releasing is a decision here, and that leaves a gap between a merge and
a tag where merged work is running nowhere anybody can look at it.

Three things differ from prod, each one in `k8s/portfolio-preprod.yaml` with
the reasoning next to it:

- **Reachable from the tailnet only**, as `git.` and `couchdb.` are. Needs a
  Cloudflare A record for `preprod` pointing at the node's *tailnet* address,
  `100.79.242.82`, DNS-only — the wildcard record points at the public IP, and
  a request arriving there has a public source address and is refused by the
  allowlist. The wildcard certificate already covers the name, so TLS needs
  nothing.
- **Its mail goes to a sink**, a Mailpit in the namespace that accepts any
  login and delivers nothing. Preprod holds no mail credential that could
  reach a real mailbox, and its `CONTACT_TO` is in `.invalid`. Read what it
  caught with `kubectl -n preprod port-forward deploy/mail 8025:8025`.
- **Its content is its own CouchDB**, with a password generated into the
  namespace. The database name is hardcoded in the API, so "same server,
  different database" would have meant changing the application to make an
  infrastructure decision — and would have left preprod holding a credential
  that can write the production store.

What it costs the node, measured rather than estimated: 100m CPU and 256Mi of
requests, against 750m/1964Mi already requested out of 2 OCPU and 11.6Gi. Real
resident use is about 145Mi — web and api are 3Mi and 20Mi in prod today,
CouchDB is 102Mi, Mailpit is some tens. That takes requested CPU from 37% to
roughly 43% and requested memory from 16% to 18%; actual memory goes from 47%
to about 48%. It fits, and the headroom that matters is CPU during a
simultaneous image pull on both namespaces rather than anything steady-state.
Nothing here moves the idle-reclamation numbers in the wrong direction —
memory is the only lever Oracle actually measures, and this adds to it.

```sh
./k8s/portfolio-apply.sh preprod  # creates web/api if missing, then applies
kubectl apply -f k8s/tailnet-only-middleware.yaml \
               -f k8s/ci-rollout-rbac.yaml
./k8s/preprod-secrets.sh        # generates what it needs; copies ghcr-pull
```

#### Seeding preprod

The store starts empty, and an empty store is the one state the notes surface
can only show as an error card. Either fixture content from the site
repository, which is what the local stack uses:

```sh
kubectl -n preprod port-forward svc/couch 5985:5984
COUCHDB_URL=http://127.0.0.1:5985 \
COUCHDB_PASSWORD=$(kubectl -n preprod get secret preprod-couch \
                     -o jsonpath='{.data.COUCHDB_PASSWORD}' | base64 -d) \
  node backend/scripts/seed-dev-content.mjs
```

That script refuses any non-loopback host on purpose — it writes documents with
"Fixture" in the title — which is why this goes through a port-forward rather
than at the Service directly.

Or replicate the real content in, one way, when what needs looking at is a
change to how existing posts render. Replicate *from* prod *to* preprod and
never the reverse; the preprod credential cannot write the production store,
which is the backstop rather than the plan.

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
2. **`KUBECONFIG_B64`** — two commands, and never the cluster-admin
   kubeconfig. A rollout needs `get`/`patch`/`watch` on the `web` and `api`
   Deployments and read on the Pods behind them, in `prod` and in `preprod`;
   anything more is a credential that can do anything to this cluster, sitting
   in a third party's secret storage.

   ```sh
   kubectl apply -f k8s/ci-rollout-rbac.yaml   # once
   ./k8s/ci-kubeconfig.sh                      # prints the value to paste
   ```

   One token covers both namespaces: `preprod` binds the same ServiceAccount
   with its own Role, rather than a ClusterRole that would have granted the
   same verbs in `monitoring`, `forgejo` and `kube-system` too. Revoke any
   time with `kubectl -n prod delete secret ci-rollout-token`.
3. **`ghcr-pull`** in the cluster, because the packages are private:

   ```sh
   kubectl -n prod create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io --docker-username=<github-user> \
     --docker-password=<PAT with read:packages>
   ```

   `preprod` needs it too; `k8s/preprod-secrets.sh` copies this one rather
   than minting a second. It is a read-only registry token for images both
   namespaces pull, so a second one would be a second thing to rotate for no
   isolation — unlike `portfolio-api-env`, which that script builds from
   scratch and never copies.

A `production` environment in the site repository is where a required reviewer
goes, if a human step before a live rollout is wanted. If the three secrets
above are ever moved from repository secrets onto that environment, they must
be added to the `preprod` environment too, or every merge fails with an empty
kubeconfig.

`kubectl create secret --from-env-file` does **not** strip quotes the way `dotenv`
does, so `CONTACT_TO="a@b.com"` arrives including the quote characters and fails
validation. Normalise before creating the secret.

The frontend's `nginx.conf` proxies `/api/` to `http://api:5000`, so the backend
Service must be named exactly `api` in the same namespace. That is also why
`preprod` repeats the names rather than suffixing them.

The API's `WEB_ORIGIN` defaults to `http://web`, which is the Service's port 80
forwarding to the container's 8080. That is correct in a namespace and wrong
anywhere there is no Service — under Docker Compose it has to be
`http://web:8080`, or every per-URL head quietly falls back to the plain SPA
shell and the page still loads with the wrong `<title>`.

## Rebuild

```sh
tofu init && tofu apply          # instance + network
kubectl apply -f k8s/            # after k3s install and kubeconfig merge
./k8s/portfolio-apply.sh prod    # web/api: the apply above cannot create them
./k8s/portfolio-apply.sh preprod
```

Secrets (`terraform.tfvars`, `.cf-token`, `.github-oauth`) are gitignored and must
be recreated by hand.
