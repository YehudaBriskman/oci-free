# Kubernetes: what runs on k3s

Everything in `k8s/` is applied to a single-node k3s cluster on the VM.
Persistent data uses k3s's `local-path` volumes on the boot disk.

## Edge

| File | What it does |
|---|---|
| `traefik-config.yaml` | configures the Traefik that k3s bundles: HTTP to HTTPS redirect, and `externalTrafficPolicy: Local` so source addresses survive for allowlists |
| `cluster-issuers.yaml`, `wildcard-cert.yaml` | cert-manager issuers (Let's Encrypt) and a wildcard certificate for the domain |
| `oauth2-proxy.yaml` | a single sign-on proxy (GitHub sign-in, single-user allowlist) that gates the admin surfaces |
| `admin-ingress.yaml`, `admin-gate.template.yaml` | the site's admin routes, behind that proxy |
| a private-only middleware | a Traefik middleware that admits only the private network, for hosts with no public audience |

Hosts that cannot complete a browser redirect (git over HTTPS, a sync client
using basic auth) are restricted to the private network instead of the sign-on
proxy, which is the stronger control anyway.

## The site (yehudabriskman.com)

| File | What it does |
|---|---|
| `portfolio.yaml` | the `prod` namespace: `web` (nginx serving the SPA) and `api` Deployments and Services |
| `portfolio-preprod.yaml` | the `preprod` namespace: the same two, plus its own CouchDB and a mail sink, private-network only and `noindex` |
| `ci-rollout-rbac.yaml` | per-environment service accounts for CI (see [Deploy](deploy.md)) |
| `couchdb-values.yaml`, `couchdb-ingress.yaml` | the shared CouchDB (Helm), reachable only from the private network and with basic auth on top |

The manifests deliberately carry **no `image:`** for `web` and `api`: CI owns
that field, so applying a manifest never reverts a deployed release.

## Platform services

| File | What it does |
|---|---|
| `forgejo-values.yaml`, `forgejo-runner.yaml` | a self-hosted Forgejo git server and its Actions runner (Helm) |
| `monitoring-values.yaml`, `grafana-netpol.yaml` | kube-prometheus-stack: Prometheus, Alertmanager and Grafana, with Grafana behind the sign-on proxy |
| `observability.yaml` | an OpenTelemetry collector, Loki and Tempo for an external app's telemetry: token-gated ingest, PII attributes deleted, default-deny network policies, Pod Security `restricted` |
| `alertmanager.yaml.tmpl`, `windom-alerts.yaml`, `windom-dashboard.yaml` | alert routing, alert rules and a dashboard for that telemetry |
| `bothy-grafana-reader.yaml` | read-only access for an external Grafana to Prometheus, Loki and Tempo, through the API server's service proxy |

## Helm releases are pinned

Every chart is installed at a recorded version, listed in the README's "Helm
releases" table, and CI renders each values file against exactly that version
(`tests/helm.sh`, which also pins each chart archive's checksum). An upgrade is
a decision, made in the same commit as the table change:

```sh
helm upgrade --install <release> <repo>/<chart> -n <namespace> \
  -f k8s/<values>.yaml --version <version from the table>
```

Traefik is the exception: k3s installs it, so its version follows k3s.

## Rebuilding the cluster

```sh
tofu init && tofu apply          # the VM and its network
# install k3s on the node, merge its kubeconfig
kubectl apply -f k8s/
./k8s/portfolio-apply.sh prod    # web/api: a plain apply cannot create them
./k8s/portfolio-apply.sh preprod
```

Then each Helm release at its recorded version, and the secrets, which are
created by the `k8s/*-secrets.sh` scripts or by hand and are never committed.
