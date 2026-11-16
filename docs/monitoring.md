# Monitoring and alerts

What is watched, at what threshold, where the email goes, and how to change or
test it. The code is `k8s/portfolio-alerts.yaml` (rules), `k8s/blackbox.yaml`
(uptime probes), `k8s/portfolio-scrapes.yaml` (two extra scrapes),
`k8s/portfolio-dashboard.yaml` and `k8s/node-dashboard.yaml` (Grafana), and the
`team = "portfolio"` route in `k8s/alertmanager.yaml.tmpl`. `tests/alerts.sh`
checks all of it offline, in CI.

## Where emails go

Alertmanager sends every `team=portfolio` (and `team=windom`) alert through the
one `email` receiver (the WindoM alerts share it). It sends through the same
Resend SMTP account prod uses: host, port, user and sender are read by
`k8s/telemetry-secrets.sh` from `prod/portfolio-api-env` (`SMTP_HOST`,
`SMTP_PORT`, `SMTP_USER`, `MAIL_FROM`), the recipient is `$ALERT_TO` or else
`CONTACT_TO`; none of them is in this repository. The password (`SMTP_PASS`)
is copied into the `alertmanager-smtp` Secret. Port 465 is implicit TLS and
Alertmanager handles that itself. The Gmail app password is retired: Gmail
rejected it with 535.

| Severity | First email | Updates | Repeat while firing | Resolved email |
|---|---|---|---|---|
| critical | at once | 1m | every 1h | yes |
| warning | after 1m | 5m | every 6h | yes |

Alerts are grouped by `alertname` and `namespace`, so one problem on ten pods is
one email. A critical mutes the same alert's warning, and a `NodeDown` mutes every
other portfolio alert (the pod, probe and edge alerts it explains). The chart's
own alerts still go to `null`. `Watchdog` goes to the external heartbeat (below).

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

Two limits worth knowing. The dead-man's switch is an *external* heartbeat
(healthchecks.io): `Watchdog` is POSTed to the ping URL in Secret
`monitoring/alertmanager-heartbeat` (key `url`, created by hand, never in git)
every 2 minutes, and the service emails the owner when pings stop (period 5 min,
grace 5 min). It covers the node, Prometheus or Alertmanager dying. `WatchdogMissing` only
catches rule loading breaking while Prometheus lives; if Prometheus or
Alertmanager is down the in-cluster email cannot be sent (the node-level and Grafana views
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
| certificates | `certmanager_certificate_*` | PodMonitor in `k8s/portfolio-scrapes.yaml` (new; controller pod port `http-metrics`, 9402) |

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
   exercises routing and the SMTP account, not the rules):

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

## Logs

Pod logs of the namespaces `prod` and `preprod` (portfolio `api`, `web`, `couch`,
`mail`) are shipped to the existing Loki by **Grafana Alloy** (`k8s/alloy.yaml`)
and shown in Grafana (dashboard **Portfolio: logs**, uid `portfolio-logs`,
`k8s/logs-dashboard.yaml`). Loki keeps them **14 days** (`retention_period: 336h`,
enforced by its compactor; `observability.yaml`), ingestion limit 4 MB/s, 8 MB
burst. A handful of low-traffic pods is orders of magnitude under that, and the
probe lines are dropped.

**How.** One Alloy replica (the cluster is one node) in `observability`, Pod
Security `restricted`. It tails logs through the Kubernetes API
(`loki.source.kubernetes`): no hostPath, no DaemonSet, no privileged container. Its
ServiceAccount can only `get/list/watch` `pods` and `get` `pods/log`, through a
Role in `prod` and one in `preprod` (no Secrets, no ConfigMaps, no other
namespace, no ClusterRole). It pushes to `loki:3100/loki/api/v1/push` (Loki's native
API, so the labels below stay plain index labels; OTLP stays WindoM's path).
NetworkPolicies keep default-deny: Alloy may reach Loki, DNS and the API server
(6443, private ranges), Loki accepts it, and Prometheus may scrape its `:12345`.

**Labels** (only these; `stage.label_keep` drops everything else): `namespace`,
`app` (the pod's `app` label, else the container name), `pod`, `container`.
Never a pod IP, request path or anything from a log line. The level is not a
label: Loki derives `detected_level` as structured metadata.

**Redaction** (second defence, before a line leaves the pod): masked as
`[email]` / `[redacted]` are email addresses, `Authorization` and `Bearer`
values, `Cookie`/`Set-Cookie` values, JWTs, and `token=`, `key=`, `secret=`,
`password=`, `sig=` values (so `api_key=abc&page=2` becomes `api_key=[redacted]&page=2`).
Dropped entirely: kube-probe requests and `/health`, `/health/ready`, `/metrics`
lines. `tests/alerts.sh` runs these patterns over sample lines.

**Privacy rules.** The apps must still not log personal data: this layer is a
net, not permission. Do not add a label from a log field; do not widen the
Roles; read logs only through Grafana (behind the SSO). 14 days is the ceiling,
see the privacy policy before raising it.

**Query it** (Grafana > Explore > Loki):

```logql
{namespace="preprod"}                                   # everything in preprod
{namespace="prod", app="api"} |= "error"                # prod API lines containing error
{namespace="prod", app="api"} | detected_level="error"  # by derived level
sum by (app) (count_over_time({namespace=~"prod|preprod"} [5m]))   # volume per app
{namespace="preprod", app="mail"} != "SMTP"             # exclude a noisy phrase
```

**Alerts** (`AlloyDown`, 10m; `AlloyDroppingLogs`, 10m; both warning). No "prod API
silent for 30m" alert: Alloy's counters have no namespace or app label and a quiet
site is legitimately silent.

**Add a namespace.** In `k8s/alloy.yaml` add a Role + RoleBinding in it (copy
`alloy-logs`), and its name to `names = [...]` and the `keep` regex in the
config; extend the namespace list in the test in `tests/alerts.sh`; apply.
Alloy rolls on a config change only if you `rollout restart` it.

## Grafana panels empty, "Plugin not registered"

Seen 2026-11-16: every dashboard and Explore were empty although Prometheus
and Loki held data. Grafana 13 tries to pre-install its bundled data sources
at start; with a read-only root filesystem that fails and prometheus, loki and
tempo vanish from the plugin list (`/api/plugins/loki/settings` says "no
installed plugin"; `/api/datasources/uid/loki/health` says "plugin.notRegistered").
Fix: `plugins.preinstall_disabled: true` in `monitoring-values.yaml`
(`GF_PLUGINS_PREINSTALL_DISABLED=true`; applied live with `kubectl set env`).
Check after any Grafana upgrade: all three data source health endpoints say OK.
