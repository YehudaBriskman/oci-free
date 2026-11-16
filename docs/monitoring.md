# Monitoring and alerts

What is watched, at what threshold, where the email goes, and how to change or
test it. The code is `k8s/portfolio-alerts.yaml` (rules), `k8s/blackbox.yaml`
(uptime probes), `k8s/portfolio-scrapes.yaml` (two extra scrapes),
`k8s/portfolio-dashboard.yaml` and `k8s/node-dashboard.yaml` (Grafana), and the
`team = "portfolio"` route in `k8s/alertmanager.yaml.tmpl`. `tests/alerts.sh`
checks all of it offline, in CI.

## Where emails go

Alertmanager sends every `team=portfolio` (and `team=windom`) alert through the
one `email` receiver, to the address the template is rendered with (the site's
`SMTP_USER`, filled in by `k8s/telemetry-secrets.sh`; it is not in this
repository). The Gmail app password stays in the `alertmanager-smtp` Secret.

| Severity | First email | Updates | Repeat while firing | Resolved email |
|---|---|---|---|---|
| critical | at once | 1m | every 1h | yes |
| warning | after 1m | 5m | every 6h | yes |

Alerts are grouped by `alertname` and `namespace`, so one problem on ten pods is
one email. A critical mutes the same alert's warning, and a `NodeDown` mutes every
other portfolio alert (the pod, probe and edge alerts it explains). The chart's
own alerts and `Watchdog` still go to `null`.

## What is alerted

Warning is 70%, critical 90% unless stated. "for" is how long the condition must
hold before the email.

**Host** (node-exporter)

| Alert | Warning | Critical |
|---|---|---|
| `NodeDown` | | node NotReady / not scraped, 2m |
| `NodeCPUHigh` | CPU > 70%, 15m | > 90%, 10m |
| `NodeMemoryHigh` | used > 70%, 15m | > 90%, 5m |
| `NodeDiskUsageHigh` | any real filesystem (root and data) > 70%, 10m | > 90%, 5m |
| `NodeDiskWillFillIn24h` | predicted full within 24h, and > 60% used, 1h | |
| `NodeInodesHigh` | inodes > 90%, 10m | |
| `NodeLoadHigh` | load per core > 1.5, 15m | > 3, 10m |
| `NodeSwapHigh` | swap > 70%, 15m | > 90%, 10m |

**Containers** in `prod`, `preprod`, `staging` (kubelet/cAdvisor, kube-state-metrics)

| Alert | Warning | Critical |
|---|---|---|
| `PodMemoryNearLimit` | working set > 70% of limit, 15m | > 90%, 5m |
| `PodOOMKilled` | | restarted and last reason OOMKilled |
| `PodCPUNearLimit` | CPU > 70% of limit, 15m | > 90%, 10m |
| `PodCPUThrottled` | throttled in > 25% of periods, 15m | |
| `PodRestartingOften` | > 3 restarts in 1h | |
| `PodCrashLooping` | | CrashLoopBackOff, 5m |
| `PodNotReady` | not ready, 5m | |
| `DeploymentReplicasUnavailable` | any unavailable, 10m | none available, 5m |
| `CouchDBDown` | | no ready replica (preprod `couch`, prod shared CouchDB in `obsidian`), 3m |
| `PVCUsageHigh` | any PVC > 70%, 10m | > 90%, 5m |
| `PVCWillFillIn24h` | predicted full within 24h, 1h | |

Usage-versus-limit alerts only see containers that **have** a limit. PVC alerts
need the kubelet to report volume stats; local-path volumes may not, in which
case the node disk alerts are the backstop (check, see "What needs what").

**Stack and uptime**

| Alert | Warning | Critical |
|---|---|---|
| `PortfolioProbeDown` | | any probe failing, 2m |
| `PortfolioProbeSlow` | probe > 2s, 10m | |
| `PortfolioProbeCertExpiring` | served cert < 14d | < 3d |
| `CertificateExpiringSoon` | cert-manager cert < 21d | < 7d |
| `CertificateNotReady` | not Ready, 15m | |
| `TraefikHigh5xxRatio` | | > 5% of a service's requests, 5m (and > 3 req/min) |
| `TraefikHighLatency` | p95 > 2s, 10m | |
| `BackupStale` / `BackupNeverSucceeded` | | CronJob (backup, forgejo) no success in 26h |
| `MonitoringComponentDown` | | Prometheus, Alertmanager, Grafana, otel-collector, Loki or Tempo has no ready replica, 5m |
| `PrometheusTargetDown` | a core scrape target down, 10m | |
| `WatchdogMissing` | | the chart's Watchdog stopped firing (rules not loaded), 10m |

Probes (`k8s/blackbox.yaml`): the public site, its MCP OAuth metadata
(`/.well-known/oauth-authorization-server`) and a public API read (`/api/content`);
the admin host, where a 302/401/403 from the SSO counts as up; and, in-cluster,
`web` and `api` (`/health`, `/health/ready`) of `prod` and `preprod`. The API's
health routes are not reachable from outside (nginx forwards only `/api/*`), and
preprod is tailnet-only at the edge, hence the in-cluster Service URLs.

Two limits worth knowing. A dead-man's switch proper (an *external* service that
emails when Alertmanager stops talking) does not exist yet; `WatchdogMissing` only
catches rule loading breaking while Prometheus lives, and if Prometheus or
Alertmanager is down the email cannot be sent (the node-level and Grafana views
are the fallback). The portfolio API exposes no `/metrics` (checked in
`portfolio_site` backend/src), so there are no application-level error-rate, mail
or queue alerts; that is a follow-up in that repository.

## What needs what

| Rules | Series | From |
|---|---|---|
| host | `node_*` | chart default |
| containers | `container_*`, `kube_*`, `kubelet_volume_stats_*` | chart default |
| probes | `probe_*` | `k8s/blackbox.yaml` (new) |
| Traefik | `traefik_service_*` | PodMonitor in `k8s/portfolio-scrapes.yaml` (new) |
| certificates | `certmanager_certificate_*` | ServiceMonitor in `k8s/portfolio-scrapes.yaml` (new) |

A rule on a series that does not exist stays silent. After applying, open
Prometheus **Status > Targets** (or run the queries in Grafana Explore) and
confirm: `up{job="blackbox-exporter"}`-style probe series, `traefik_service_requests_total`,
`certmanager_certificate_ready_status`, `kubelet_volume_stats_used_bytes`. Anything
empty is a rule not yet watching anything.

## Silence an alert

In Grafana (Alerting > Silences, choosing the Alertmanager data source) or in the
Alertmanager UI, add a silence matching `alertname` (and `namespace` if needed)
with an expiry. Or from a shell that reaches the cluster:

```sh
kubectl -n monitoring exec -it sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
  amtool silence add alertname=NodeCPUHigh --duration=2h --comment="load test" \
  --alertmanager.url=http://localhost:9093
```

## Add or change a rule

1. Edit `k8s/portfolio-alerts.yaml`. Keep `team: portfolio`, a `severity` of
   `warning` or `critical`, and `summary` and `description` annotations. Give the
   critical and warning versions the **same** `alertname`, so the inhibit rule
   pairs them.
2. `tests/alerts.sh` (needs docker or `promtool`/`amtool`). Add a case to
   `tests/alerts-unit.yml` for anything with a non-obvious expression.
3. Apply: `kubectl apply -f k8s/portfolio-alerts.yaml`. The operator reloads
   Prometheus on its own.

A new alert on a new team needs its own route in `k8s/alertmanager.yaml.tmpl`
and a re-render of the Secret (below); `team=portfolio` needs neither.

## Change routing

Edit `k8s/alertmanager.yaml.tmpl`, then `./k8s/telemetry-secrets.sh` (it re-renders
the `alertmanager-config` Secret; the operator reloads Alertmanager). Never apply
the `.tmpl` directly.

## Test an alert safely

Nothing here needs a real outage.

1. **Send a synthetic alert** straight to Alertmanager, from the node (this
   exercises routing and Gmail, not the rules):

   ```sh
   kubectl -n monitoring exec sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
     amtool alert add alertname=PortfolioTestAlert team=portfolio severity=critical namespace=prod \
     --annotation=summary="Test alert, ignore" \
     --annotation=description="Fired by hand to test email delivery." \
     --alertmanager.url=http://localhost:9093
   ```

   A critical arrives within seconds, a resolve email after about 5 minutes
   (`resolve_timeout`). Use `severity=warning` to see the one-minute grouping.
2. **Fire a real rule with a temporary low threshold**: apply a throwaway
   PrometheusRule whose expression is always true, wait for the email, delete it.

   ```sh
   kubectl apply -f - <<'EOF'
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata: {name: portfolio-test, namespace: monitoring, labels: {release: kube-prometheus-stack}}
   spec:
     groups:
       - name: portfolio-test
         rules:
           - alert: PortfolioTestRule
             expr: vector(1)
             for: 1m
             labels: {team: portfolio, severity: warning}
             annotations: {summary: "Test rule, ignore", description: "Temporary; delete it."}
   EOF
   kubectl -n monitoring delete prometheusrule portfolio-test
   ```
3. **Check the routing offline**, no cluster: `tests/alerts.sh` runs
   `amtool config routes test` for each case.
