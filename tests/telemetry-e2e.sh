#!/usr/bin/env bash
# End-to-end test of WindoM's telemetry path (#14), from the configs that are
# actually deployed: the ConfigMaps in k8s/observability.yaml, the Loki rules
# in k8s/windom-alerts.yaml and k8s/alertmanager.yaml.tmpl. It runs the same
# pinned images on a throwaway docker network and asserts what the security
# comments in those files promise:
#
#   1. OTLP without a token, or with a wrong one, is refused (401).
#   2. Logs, metrics and traces with the token are accepted (200).
#   3. PII attributes (client.address, user.email, enduser.*,
#      http.request.header.*) never reach Loki, Tempo or the Prometheus
#      exporter, and url.full loses its query string.
#   4. A `auth.token_reuse_detected` log makes the Loki ruler fire
#      WindomTokenReuse into Alertmanager, routed to receiver `email`.
#
#   tests/telemetry-e2e.sh        # needs docker, curl, jq, python3 with PyYAML
#
# Done by hand once on 2026-11-04; this is that, repeatable. Runs locally and
# in CI (path-filtered there to the three files above).
#
# What differs from the cluster, and why each is safe:
#   - Container names and network aliases stand in for Service DNS. Alertmanager
#     gets the alias `kube-prometheus-stack-alertmanager.monitoring.svc`, so
#     Loki's alertmanager_url is used unchanged.
#   - The Loki rule group's `interval: 1m` becomes 10s, so the alert fires in
#     seconds rather than a minute. The expressions are untouched.
#   - smtp.gmail.com resolves to 127.0.0.1 inside Alertmanager, so the email
#     receiver is routed to but nothing leaves the machine.
#   - The ingest token is random per run and the SMTP password a placeholder.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

OTELCOL_IMAGE=otel/opentelemetry-collector-contrib:0.164.0
LOKI_IMAGE=grafana/loki:3.7.9
TEMPO_IMAGE=grafana/tempo:2.10.10
ALERTMANAGER_IMAGE=prom/alertmanager:v0.34.2

# The images must be the ones the manifests deploy: a bump there without one
# here would test the old version and pass.
for img in "$OTELCOL_IMAGE" "$LOKI_IMAGE" "$TEMPO_IMAGE"; do
  grep -qF "image: $img" k8s/observability.yaml || {
    echo "FAIL: $img is not the image k8s/observability.yaml deploys; update this script" >&2
    exit 1
  }
done

for c in docker curl jq python3 openssl; do
  command -v "$c" >/dev/null || { echo "need $c" >&2; exit 2; }
done

RUN=tele-e2e-$$
NET=$RUN
work=$(mktemp -d)
pass=0
fail=0

ok() { echo "  ok   $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }
is() { # is <got> <want> <what>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi
}

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] || [ "$fail" -ne 0 ]; then
    for c in otelcol loki tempo alertmanager; do
      echo "--- last log lines of $c"
      docker logs --tail 30 "$RUN-$c" 2>&1 | sed 's/^/    /' || true
    done
  fi
  docker rm -f "$RUN-otelcol" "$RUN-loki" "$RUN-tempo" "$RUN-alertmanager" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# ------------------------------------------------------------ the configs --
python3 -I - k8s "$work" <<'PY'
import os, re, sys
import yaml

k8s, out = sys.argv[1], sys.argv[2]

def configmaps(path):
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if doc and doc.get("kind") == "ConfigMap":
                yield doc["metadata"]["name"], doc["data"]

cms = {}
for f in ("observability.yaml", "windom-alerts.yaml"):
    cms.update(configmaps(os.path.join(k8s, f)))

def write(rel, text):
    p = os.path.join(out, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)

write("otelcol/config.yaml", cms["otel-collector"]["config.yaml"])
write("loki/config.yaml", cms["loki"]["config.yaml"])
write("tempo/config.yaml", cms["tempo"]["config.yaml"])

rules = cms["loki-rules"]["windom.yaml"]
n = len(re.findall(r"(?m)^(\s*)interval: 1m$", rules))
if n != 1:
    sys.exit(f"expected one `interval: 1m` in loki-rules, found {n}")
write("rules/fake/windom.yaml", re.sub(r"(?m)^(\s*)interval: 1m$", r"\1interval: 10s", rules))

with open(os.path.join(k8s, "alertmanager.yaml.tmpl")) as f:
    am = f.read().replace("__SMTP_USER__", "alerts@example.invalid")
write("alertmanager/alertmanager.yml", am)
write("alertmanager/smtp/password", "placeholder-not-a-secret")
PY
chmod -R a+rX "$work"

TOKEN=$(openssl rand -hex 32)

# ------------------------------------------------------------ the stack ----
echo "starting the stack ($RUN)"
docker network create "$NET" >/dev/null

# All four as in the cluster: uid 10001 (Alertmanager: its image's nobody),
# read-only root filesystem, writable only where a volume is mounted.
docker run -d --name "$RUN-alertmanager" --network "$NET" \
  --network-alias kube-prometheus-stack-alertmanager.monitoring.svc \
  --add-host smtp.gmail.com:127.0.0.1 \
  --read-only --tmpfs /alertmanager:uid=65534,gid=65534 \
  -v "$work/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
  -v "$work/alertmanager/smtp:/etc/alertmanager/secrets/alertmanager-smtp:ro" \
  -p 127.0.0.1::9093 \
  "$ALERTMANAGER_IMAGE" --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager >/dev/null

docker run -d --name "$RUN-loki" --network "$NET" --network-alias loki \
  --user 10001:10001 --read-only --tmpfs /loki:uid=10001,gid=10001 \
  -v "$work/loki/config.yaml:/etc/loki/config.yaml:ro" \
  -v "$work/rules:/etc/loki/rules:ro" \
  -p 127.0.0.1::3100 \
  "$LOKI_IMAGE" -config.file=/etc/loki/config.yaml -target=all >/dev/null

docker run -d --name "$RUN-tempo" --network "$NET" --network-alias tempo \
  --user 10001:10001 --read-only --tmpfs /var/tempo:uid=10001,gid=10001 \
  -v "$work/tempo:/etc/tempo:ro" \
  -p 127.0.0.1::3200 \
  "$TEMPO_IMAGE" -config.file=/etc/tempo/config.yaml >/dev/null

# The token reaches the collector through the environment, as the Secret does.
docker run -d --name "$RUN-otelcol" --network "$NET" \
  --user 10001:10001 --read-only \
  -e OTLP_TOKEN="$TOKEN" \
  -v "$work/otelcol:/etc/otelcol:ro" \
  -p 127.0.0.1::4318 -p 127.0.0.1::8889 -p 127.0.0.1::13133 \
  "$OTELCOL_IMAGE" --config=/etc/otelcol/config.yaml >/dev/null

addr() { docker port "$RUN-$1" "$2/tcp" | head -1; }
OTLP=http://$(addr otelcol 4318)
PROM=http://$(addr otelcol 8889)
HEALTH=http://$(addr otelcol 13133)
LOKI=http://$(addr loki 3100)
TEMPO=http://$(addr tempo 3200)
AM=http://$(addr alertmanager 9093)

# wait_for <what> <url> <seconds>
wait_for() {
  local i
  for ((i = 0; i < $3; i++)); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$2")" = 200 ]; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL: $1 not ready at $2 after $3s" >&2
  exit 1
}
wait_for alertmanager "$AM/-/ready" 60
wait_for loki "$LOKI/ready" 120
wait_for tempo "$TEMPO/ready" 120
wait_for otel-collector "$HEALTH/" 60
echo "stack ready"

# ------------------------------------------------------------ payloads -----
# Sentinels: values that must never appear anywhere downstream.
IP=203.0.113.77
EMAIL=leak-sentinel@example.invalid
ENDUSER=enduser-sentinel
HEADER=header-sentinel-value
QUERY=qs-sentinel
NOW=$(date +%s%N)
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
MARK=e2e-$RUN

# pii_attrs: the attributes the collector must delete, plus url.full with a
# query string and a harmless one that must survive (positive control).
pii_attrs() {
  cat <<JSON
{"key":"client.address","value":{"stringValue":"$IP"}},
{"key":"user.email","value":{"stringValue":"$EMAIL"}},
{"key":"enduser.id","value":{"stringValue":"$ENDUSER"}},
{"key":"http.request.header.authorization","value":{"stringValue":"$HEADER"}},
{"key":"url.full","value":{"stringValue":"https://windom.example/v1/login?token=$QUERY"}},
{"key":"e2e.mark","value":{"stringValue":"$MARK"}}
JSON
}
resource() {
  cat <<JSON
{"attributes":[{"key":"service.name","value":{"stringValue":"windom-api"}},
  {"key":"client.address","value":{"stringValue":"$IP"}}]}
JSON
}

cat >"$work/logs.json" <<JSON
{"resourceLogs":[{"resource":$(resource),"scopeLogs":[{"logRecords":[{
  "timeUnixNano":"$NOW","severityText":"WARN","body":{"stringValue":"token reuse $MARK"},
  "attributes":[{"key":"event.name","value":{"stringValue":"auth.token_reuse_detected"}},$(pii_attrs)]}]}]}]}
JSON
cat >"$work/traces.json" <<JSON
{"resourceSpans":[{"resource":$(resource),"scopeSpans":[{"spans":[{
  "traceId":"$TRACE_ID","spanId":"$SPAN_ID","name":"POST /v1/login","kind":2,
  "startTimeUnixNano":"$NOW","endTimeUnixNano":"$((NOW + 5000000))",
  "attributes":[$(pii_attrs)],
  "events":[{"timeUnixNano":"$NOW","name":"e2e-event","attributes":[$(pii_attrs)]}]}]}]}]}
JSON
cat >"$work/metrics.json" <<JSON
{"resourceMetrics":[{"resource":$(resource),"scopeMetrics":[{"metrics":[{
  "name":"e2e_probe","gauge":{"dataPoints":[{"timeUnixNano":"$NOW","asInt":"1",
  "attributes":[$(pii_attrs)]}]}}]}]}]}
JSON
for f in logs traces metrics; do jq -e . "$work/$f.json" >/dev/null; done

# post <signal> [token]: prints the HTTP status. The header goes in through a
# file, not argv, like the scripts this repo ships.
post() {
  local hdr="$work/hdr"
  : >"$hdr"
  if [ -n "${2:-}" ]; then printf 'Authorization: Bearer %s\n' "$2" >"$hdr"; fi
  curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -H @"$hdr" --data-binary @"$work/$1.json" "$OTLP/v1/$1"
}

# ------------------------------------------------------------ 1. auth ------
echo "1. the bearer token is the gate"
for sig in logs metrics traces; do
  is "$(post "$sig")" 401 "$sig without a token: 401"
  is "$(post "$sig" "wrong-$TOKEN")" 401 "$sig with a wrong token: 401"
done

# ------------------------------------------------------------ 2. ingest ----
echo "2. with the token, everything is accepted"
for sig in logs metrics traces; do
  is "$(post "$sig" "$TOKEN")" 200 "$sig with the token: 200"
done

# ------------------------------------------------------------ 3. PII -------
# no_pii <where> <file>: none of the sentinel values, none of the attribute
# keys in either their dotted (Tempo) or underscored (Loki, Prometheus) form.
no_pii() {
  local hits
  hits=$(grep -oE "$IP|$EMAIL|$ENDUSER|$HEADER|$QUERY|client[._]address|user[._]email|enduser[._][a-z]+|http[._]request[._]header[._][a-z]+|\?token=" "$2" | sort -u | tr '\n' ' ' || true)
  if [ -z "$hits" ]; then ok "$1: no PII attribute or value"; else bad "$1 leaks: $hits"; fi
}

echo "3. PII is gone downstream"
loki_json=$work/loki.json
found=0
for _ in $(seq 1 30); do
  curl -s -G "$LOKI/loki/api/v1/query_range" \
    --data-urlencode 'query={service_name="windom-api"}' \
    --data-urlencode "start=$((NOW - 60000000000))" --data-urlencode limit=50 >"$loki_json"
  if grep -q "$MARK" "$loki_json"; then found=1; break; fi
  sleep 2
done
if [ "$found" = 1 ]; then
  ok "loki: the log line arrived"
  no_pii loki "$loki_json"
  url=$(jq -r '[.data.result[].stream.url_full // empty] | first // "missing"' "$loki_json")
  is "$url" https://windom.example/v1/login "loki: url.full has no query string"
  ev=$(jq -r '[.data.result[].stream.event_name // empty] | first // "missing"' "$loki_json")
  is "$ev" auth.token_reuse_detected "loki: event_name kept (alerts match on it)"
else
  bad "loki: the log line never arrived"
fi

tempo_json=$work/tempo.json
found=0
for _ in $(seq 1 30); do
  if [ "$(curl -s -o "$tempo_json" -w '%{http_code}' "$TEMPO/api/traces/$TRACE_ID")" = 200 ] && grep -q "$MARK" "$tempo_json"; then
    found=1; break
  fi
  sleep 2
done
if [ "$found" = 1 ]; then
  ok "tempo: the trace arrived"
  no_pii tempo "$tempo_json"
  url=$(jq -r '[.. | objects | select(.key? == "url.full") | .value.stringValue] | unique | join(",")' "$tempo_json")
  is "$url" https://windom.example/v1/login "tempo: url.full has no query string (span and event)"
else
  bad "tempo: the trace never arrived"
fi

prom=$work/prom.txt
found=0
for _ in $(seq 1 15); do
  curl -s "$PROM/metrics" >"$prom" || true
  if grep -q '^e2e_probe' "$prom"; then found=1; break; fi
  sleep 2
done
if [ "$found" = 1 ]; then
  ok "prometheus exporter: the metric arrived"
  no_pii "prometheus exporter" "$prom"
else
  bad "prometheus exporter: e2e_probe never appeared"
fi

# ------------------------------------------------------------ 4. alert -----
echo "4. token reuse pages through Alertmanager"
alerts=$work/alerts.json
found=0
for _ in $(seq 1 60); do
  curl -s -G "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="WindomTokenReuse"' >"$alerts" || true
  if jq -e 'length > 0' "$alerts" >/dev/null 2>&1; then found=1; break; fi
  sleep 3
done
if [ "$found" = 1 ]; then
  ok "loki ruler fired WindomTokenReuse into alertmanager"
  is "$(jq -r '[.[0].receivers[].name] | join(",")' "$alerts")" email "routed to receiver 'email'"
  is "$(jq -r '.[0].labels | "\(.team)/\(.severity)"' "$alerts")" windom/page "labels team=windom severity=page"
else
  bad "WindomTokenReuse never reached alertmanager"
fi

echo
echo "telemetry e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
