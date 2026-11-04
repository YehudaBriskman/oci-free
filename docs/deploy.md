# Deploying the site: rollout scripts

The site's images are built, scanned and published by the site repository's
CI ([portfolio_site](https://github.com/YehudaBriskman/portfolio_site), see its
[deploy manual](https://github.com/YehudaBriskman/portfolio_site/blob/main/docs/manual/deploy.md)).
This repository holds the cluster side: where those images run, and what CI is
allowed to do there.

```
push to main ──▶ build + test + scan ──▶ GHCR, by digest ──▶ set image ──▶ preprod
push a tag   ──▶ re-scan the same digests ─────────────────▶ set image ──▶ prod
                                                                │
                                         rollout status ──▶ the site answers?
                                                                │
                                                   no ──▶ put back what ran before
```

CI reaches the Kubernetes API over the private network for the length of the
job only; the API server is never exposed to the internet.

## CI owns the image

`web` and `api` in `k8s/portfolio.yaml` and `k8s/portfolio-preprod.yaml` have no
`image:` field, so `kubectl apply` updates everything else and leaves the
running digest alone. A Deployment cannot be created without an image, so the
first apply into a namespace goes through a script:

```sh
./k8s/portfolio-apply.sh prod       # or preprod; safe to re-run
```

It creates a missing Deployment at the `:latest` tag (which means "the last
release" and moves only after a passing production rollout), applies the
manifest over it, and lets CI's next deploy pin a digest. It refuses to run
against any cluster other than this one.

## What CI may do

`k8s/ci-rollout-rbac.yaml` declares one service account per job, and
`k8s/ci-kubeconfig.sh` prints a kubeconfig for each:

| Account | Can do |
|---|---|
| preprod deploy | roll out `web` and `api` in `preprod` only |
| prod deploy | roll out `web` and `api` in `prod` only |
| drift reader | read `web` and `api` in both; nothing else |

Each kubeconfig is stored as a secret of the matching GitHub environment, and
each environment admits only its own refs (`main` for preprod, `v*` tags for
production), so a branch cannot read the production credential.

`patch` on a Deployment is effectively control of its whole pod template, so a
deploy credential is worth everything in its namespace. Splitting them keeps
the preprod credential, which every merge uses, from also being the production
one. The post-rollout readiness check reads the two Services through the API
server's service proxy, limited to those two names.

```sh
./k8s/ci-kubeconfig.sh <account>                     # a non-expiring token
./k8s/ci-kubeconfig.sh <account> --duration 2160h    # an expiring one; re-run to rotate
```

## Preprod

The same two Deployments in their own namespace, carrying whatever is on
`main`, so merged work is running somewhere before it is released. It differs
from production in three ways, each explained in `k8s/portfolio-preprod.yaml`:

- reachable from the private network only, with a `noindex` header behind the
  allowlist;
- its mail goes to a sink that delivers nothing;
- its content is its own CouchDB, so it holds no credential that can write the
  production store.

`k8s/preprod-secrets.sh` generates what preprod needs and copies only the
read-only registry pull secret from production.

## The fallback

`deploy-portfolio.sh` is the old route: it syncs a working directory to the
node and builds there. It is kept for when CI cannot reach the cluster, and it
is not the normal path because it can ship code that was never committed.
