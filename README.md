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

Memory inside the A1 is shared by everything in k8s/. The WindoM telemetry
stack (#14) requests about 420 MiB (collector 96, Loki 192, Tempo 128), with
limits of about 1.3 GiB, plus two 10 Gi `local-path` volumes on the boot disk.
Retention is set in its config, not by disk: logs 14 days, traces 7, metrics
15 (Prometheus, unchanged). The privacy policy promises 30 days or less.

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
| `otel.` | public | bearer token, checked by the OTel collector (Fly cannot do OAuth); 4 MiB body cap, rate limit |

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

Secrets in the **site** repository, one in the cluster.

1. **`TS_OAUTH_CLIENT_ID`** / **`TS_OAUTH_SECRET`** — a Tailscale OAuth client
   with the `auth_keys` scope, plus an ACL grant letting `tag:ci` reach this
   node.
2. **A kubeconfig per job, never the cluster-admin one** (#16).
   `k8s/ci-rollout-rbac.yaml` declares three accounts and
   `k8s/ci-kubeconfig.sh` prints a kubeconfig for each:

   | secret | where it lives in GitHub | account | can do |
   |---|---|---|---|
   | `KUBECONFIG_PREPROD` | `preprod` environment | `preprod/ci-deploy` | roll out `web`/`api` in `preprod` only |
   | `KUBECONFIG_PROD` | `production` environment | `prod/ci-deploy` | roll out `web`/`api` in `prod` only |
   | `KUBECONFIG_DRIFT` | repository | `prod/ci-drift` | `get` `web`/`api` in both; nothing else |

   ```sh
   kubectl apply -f k8s/ci-rollout-rbac.yaml   # once
   R=YehudaBriskman/portfolio_site
   ./k8s/ci-kubeconfig.sh preprod | gh secret set KUBECONFIG_PREPROD -R "$R" --env preprod
   ./k8s/ci-kubeconfig.sh prod    | gh secret set KUBECONFIG_PROD    -R "$R" --env production
   ./k8s/ci-kubeconfig.sh drift   | gh secret set KUBECONFIG_DRIFT   -R "$R"
   ```

   **What a deploy token can actually do.** It is not "set image and nothing
   else". RBAC grants verbs on objects, not fields, so `patch` on
   `deployments/web` is a rewrite of the whole pod template: any command, any
   Secret in the namespace through `envFrom`, any ServiceAccount in the
   namespace, and — unless admission refuses it — `privileged`, `hostPath: /`
   and `hostNetwork`. On one node that last group is root on the node. So a
   deploy token is worth everything in its namespace, and until Pod Security
   enforces `baseline` there (#20), the node. The split is what stops the
   preprod token, which every merge to `main` decrypts, from also being the
   prod token; #20 is what closes the escalation itself.

   **An environment secret is only as gated as the environment's branch
   policy.** Without one, any branch can declare `environment: production` and
   read `KUBECONFIG_PROD`. So `production` admits only `v*` tags and `preprod`
   only `main` (the commands are under "Retiring the shared token" below). A
   required reviewer on `production` is optional on top.

   The readiness check after a rollout reads `api:5000/health/ready` and
   `web:80` through the API server's service proxy: `get` on
   `services/proxy`, those two names only (#24). It used to be
   `create` on `pods/portforward`, which reached every pod in the namespace —
   Mailpit and CouchDB in preprod — and landed on the api's loopback, which
   `ADMIN_API_TOKENS=tunnel` trusts. What remains is any GET on `web` or `api`
   without passing preprod's gate; the admin routes keep their own auth.

   Tokens: the default never expires and is revoked by deleting its
   `*-token` Secret (`kubectl -n preprod delete secret ci-deploy-token`; apply
   the file again to mint a new one, then re-run the matching line above).
   `./k8s/ci-kubeconfig.sh prod --duration 2160h` mints an expiring token
   instead, and re-running it before it lapses is the rotation.
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

### Retiring the shared token

Before #16, one account (`prod/ci-rollout`) was bound in both namespaces and
its token was the repository secret `KUBECONFIG_B64`, readable by every job.
`ci-rollout-rbac.yaml` no longer declares it, but applying the file does not
delete it either, so the old secret keeps working until the last step. In
this order — each step leaves both pipelines working:

```sh
R=YehudaBriskman/portfolio_site
# 1. The new accounts, beside the old one.
kubectl apply -f k8s/ci-rollout-rbac.yaml
# 2. Both environments already exist (the deploy job created them), with no
#    rules. Give each a branch policy so only its own refs can read its
#    secrets. This PUT sets the whole protection config; add "reviewers"
#    to production's JSON here if a human approval is wanted.
gh api -X PUT "repos/$R/environments/preprod" --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST "repos/$R/environments/preprod/deployment-branch-policies" -f name=main -f type=branch
gh api -X PUT "repos/$R/environments/production" --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST "repos/$R/environments/production/deployment-branch-policies" -f name='v*' -f type=tag
# 3. The three secrets (step 2 of One-time setup above).
# 4. Merge the site PR that reads them. Watch one preprod rollout, and the
#    next release's prod rollout (or a Deploy drift run by hand), go green.
# 5. Only then: the shared secret, and the account behind it.
gh secret delete KUBECONFIG_B64 -R "$R"
kubectl -n prod delete secret ci-rollout-token
kubectl -n preprod delete rolebinding ci-rollout
kubectl -n preprod delete role ci-rollout
kubectl -n prod delete rolebinding ci-rollout
kubectl -n prod delete role ci-rollout
kubectl -n prod delete serviceaccount ci-rollout
```

Deleting the GitHub secret is not revocation — anything that ever read it
still holds a working token — which is why the cluster side is deleted too.
`kubectl get sa,role,rolebinding -A | rg ci-rollout` should then print nothing.

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

## Telemetry (WindoM, #14)

`otel.yehudabriskman.com` takes OTLP/HTTP from WindoM on Fly. The collector
deletes PII attributes, then sends logs to Loki, traces to Tempo, and metrics
to Prometheus (which scrapes it). Alerts email through Alertmanager. The
namespace runs default-deny NetworkPolicies and Pod Security `restricted`.

First install, in this order (`kubectl` on the node, as for the other scripts):

```sh
kubectl apply -f k8s/observability.yaml      # namespace, policies, workloads
./k8s/telemetry-secrets.sh                   # token + SMTP + Alertmanager config
kubectl apply -f k8s/windom-alerts.yaml -f k8s/windom-dashboard.yaml
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f k8s/monitoring-values.yaml \
  --version "$(helm -n monitoring list -o json | jq -r '.[]|select(.name=="kube-prometheus-stack").chart' | sed 's/.*-//')"
./k8s/otel-token-to-fly.sh                   # from your machine: switches WindoM on
```

The collector stays in `CreateContainerConfigError` until the second step has
created its token. That is expected. Rotate with
`telemetry-secrets.sh --rotate-token`, then `otel-token-to-fly.sh`. Rotating
breaks ingest until Fly has the new token, and `WindomSilent` tells you if
that step was missed.

## Rebuild

```sh
tofu init && tofu apply          # instance + network
kubectl apply -f k8s/            # after k3s install and kubeconfig merge
./k8s/portfolio-apply.sh prod    # web/api: the apply above cannot create them
./k8s/portfolio-apply.sh preprod
```

Then the Helm releases below, each at its recorded `--version`.

Secrets (`terraform.tfvars`, `.cf-token`, `.github-oauth`) are gitignored and must
be recreated by hand.

## Helm releases

Until #25 no chart version was written down anywhere, so a rebuild would have
installed whatever each chart was on the day. The versions below are the ones
the cluster runs and the ones to install. CI renders each values file against
exactly these versions (`tests/helm.sh`, which also pins each chart archive's
sha256), so a values change that the installed chart cannot render fails the
pull request. To re-read them from the live cluster:

```sh
helm list -A -o json \
  | jq -r '.[] | "| `\(.name)` | `\(.namespace)` | `\(.chart)` | \(.app_version) |"'
helm repo list                   # the repository URL each chart came from
```

| Release | Namespace | Chart (name-version) | App version | Repository | Values |
|---|---|---|---|---|---|
| `kube-prometheus-stack` | `monitoring` | `kube-prometheus-stack-89.2.2` | v0.93.1 | `https://prometheus-community.github.io/helm-charts` | `k8s/monitoring-values.yaml` |
| `forgejo` | `forgejo` | `forgejo-17.1.5` | 15.0.7 | `oci://code.forgejo.org/forgejo-helm/forgejo` | `k8s/forgejo-values.yaml` |
| `couchdb` | `obsidian` | `couchdb-4.6.3` | 3.5.1 | `https://apache.github.io/couchdb-helm` | `k8s/couchdb-values.yaml` |
| cert-manager | | v1.21.1 | v1.21.1 | | none |

The release names and namespaces follow from the Services the Ingresses in
`k8s/` point at (`forgejo-http`, `couchdb-couchdb` in `obsidian`). cert-manager
runs v1.21.1 with no values file in this repository, so CI has nothing of it
to render (its chart is `cert-manager` v1.21.1 at `https://charts.jetstack.io`
if it is reinstalled with Helm); its kinds (`Certificate`, `ClusterIssuer`)
are schema-checked by `tests/manifests.sh`.

Every install or upgrade names the version, so an upgrade is a decision and
not a side effect of `helm repo update`:

```sh
helm upgrade --install <release> <repo>/<chart> -n <namespace> \
  -f k8s/<values>.yaml --version <version from the table>
```

Bump a version by changing the table in the same commit as the upgrade. Traefik
is not in this table: k3s installs it from its own bundled HelmChart, so its
version follows the k3s version.

## CI and tests

`.github/workflows/ci.yml` runs on every pull request and push to `main`. The
repository is private on GitHub Free, so there is no branch protection and no
GitHub secret scanning: this workflow is the only automated guard. Read the
`CI gate` check; it fails if any job failed, and passes over a job that was
skipped only because the change did not touch its paths.

| Job | What it holds | Run it locally |
|---|---|---|
| Secrets | no credential in the commits a PR or push adds (gitleaks, redacted); weekly full history in `secret-scan.yml` | `.github/scripts/secret-scan.sh install`, then `MODE=full` `scan` |
| Shell | shellcheck over every script | `.github/scripts/tools.sh install shellcheck` |
| Manifests | `k8s/*.yaml` schema-valid, strict, with pinned CRD schemas | `tests/manifests.sh` |
| Helm | each values file renders at the version in the table above | `tests/helm.sh` |
| OpenTofu | `fmt -check`, `validate` against the locked provider | `tofu init -backend=false && tofu validate` |
| Telemetry e2e | the token gate, PII stripping, and `WindomTokenReuse` paging `email`, from the deployed configs in docker | `tests/telemetry-e2e.sh` |
| Scripts | wrong-context guard, image migration, secrets kept off argv, with stub `kubectl` | `tests/scripts.sh` |

Tools are pinned with checksums in `.github/scripts/tools.sh`; `install` puts
them in `~/.cache/oci-free-tools/bin` off a runner. Helm, OpenTofu and the
telemetry e2e run only when their files change (`.github/scripts/ci-classify.sh`).
