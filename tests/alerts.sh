#!/usr/bin/env bash
# Offline checks for the monitoring code (#54), nothing touches a cluster:
#
#   1. Every alert in k8s/portfolio-alerts.yaml has a team label, a severity of
#      warning or critical, a summary and a description, and the object carries
#      the `release: kube-prometheus-stack` label the chart's ruleSelector needs.
#   2. `promtool check rules` accepts the rule groups of every PrometheusRule in
#      k8s/ (expressions, `for`, and the annotation templates), and
#      `promtool test rules` (tests/alerts-unit.yml) proves a few of them fire.
#   3. Every Grafana dashboard ConfigMap holds valid JSON with a stable, unique
#      uid and unique panel ids.
#   4. alertmanager.yaml.tmpl, rendered with dummy SMTP values (port 465), passes
#      `amtool check-config`, and the routes do what docs/monitoring.md says
#      (`amtool config routes test`): portfolio critical/warning and windom go
#      to `email`, Watchdog to `heartbeat` (the external dead-man switch) and anything else to `null`.
#
#   tests/alerts.sh     # needs python3 with PyYAML, and promtool/amtool on PATH
#                       # or docker (the pinned prom/* images are then used)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

PROMETHEUS_IMAGE=prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06
ALERTMANAGER_IMAGE=prom/alertmanager:v0.34.2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 755 "$work"

# 1 + 3: structure, in python (PyYAML is on the runner and the e2e job already
# needs it). Writes one rules file per PrometheusRule for promtool.
python3 -I - "$work" <<'PY'
import glob, json, os, sys, yaml

work = sys.argv[1]
errors = []
alerts = 0

for path in sorted(glob.glob("k8s/*.yaml")):
    if path.endswith("-values.yaml"):
        continue
    with open(path) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    for d in docs:
        kind, name = d.get("kind"), d.get("metadata", {}).get("name")
        if kind == "PrometheusRule":
            if d["metadata"].get("labels", {}).get("release") != "kube-prometheus-stack":
                errors.append(f"{path}: PrometheusRule {name} lacks label release=kube-prometheus-stack (the chart would ignore it)")
            with open(os.path.join(work, f"rules-{name}.yml"), "w") as out:
                yaml.safe_dump({"groups": d["spec"]["groups"]}, out)
            if os.path.basename(path) != "portfolio-alerts.yaml":
                continue
            for g in d["spec"]["groups"]:
                for r in g["rules"]:
                    if "alert" not in r:
                        continue
                    alerts += 1
                    who = f"{path}: {r['alert']}"
                    labels = r.get("labels", {})
                    ann = r.get("annotations", {})
                    if labels.get("team") != "portfolio":
                        errors.append(f"{who}: team label must be 'portfolio'")
                    if labels.get("severity") not in ("warning", "critical"):
                        errors.append(f"{who}: severity must be warning or critical")
                    for k in ("summary", "description"):
                        if not str(ann.get(k, "")).strip():
                            errors.append(f"{who}: missing annotation {k}")
        if kind == "ConfigMap" and d["metadata"].get("labels", {}).get("grafana_dashboard") == "1":
            for key, text in d["data"].items():
                where = f"{path}:{name}/{key}"
                try:
                    dash = json.loads(text)
                except ValueError as e:
                    errors.append(f"{where}: invalid JSON: {e}")
                    continue
                uid = dash.get("uid")
                if not uid:
                    errors.append(f"{where}: no uid")
                seen = {}
                def walk(panels):
                    for p in panels:
                        if p["id"] in seen:
                            errors.append(f"{where}: duplicate panel id {p['id']}")
                        seen[p["id"]] = 1
                        walk(p.get("panels", []))
                walk(dash.get("panels", []))
                with open(os.path.join(work, "uids"), "a") as u:
                    u.write(f"{uid}\t{where}\n")

uids = {}
if os.path.exists(os.path.join(work, "uids")):
    for line in open(os.path.join(work, "uids")):
        uid, where = line.rstrip("\n").split("\t")
        if uid in uids:
            errors.append(f"dashboard uid {uid} is used by both {uids[uid]} and {where}")
        uids[uid] = where
if alerts == 0:
    errors.append("no alerts found in k8s/portfolio-alerts.yaml")
if errors:
    print("\n".join("FAIL " + e for e in errors))
    sys.exit(1)
print(f"ok   {alerts} portfolio alerts have team, severity, summary and description")
print(f"ok   {len(uids)} dashboards are valid JSON with unique uids")
PY

# 5: the log shipper (k8s/alloy.yaml, #61) is Pod Security `restricted`
# compatible, can read nothing but pods and their logs in prod/preprod, is
# fenced by NetworkPolicy, and its redaction stages mask what they claim to.
python3 -I - <<'PY'
import re, sys, yaml

errors = []
with open("k8s/alloy.yaml") as f:
    docs = [d for d in yaml.safe_load_all(f) if d]
by = lambda kind: [d for d in docs if d["kind"] == kind]

dep = [d for d in by("Deployment") if d["metadata"]["name"] == "alloy"]
if len(dep) != 1:
    errors.append("alloy.yaml: expected one Deployment alloy")
else:
    spec = dep[0]["spec"]["template"]["spec"]
    psc = spec.get("securityContext", {})
    if psc.get("runAsNonRoot") is not True: errors.append("alloy: pod runAsNonRoot must be true")
    if psc.get("seccompProfile", {}).get("type") != "RuntimeDefault": errors.append("alloy: seccompProfile RuntimeDefault missing")
    for k in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(k): errors.append(f"alloy: {k} is set")
    for v in spec.get("volumes", []):
        if "hostPath" in v: errors.append(f"alloy: hostPath volume {v['name']}")
    for c in spec["containers"] + spec.get("initContainers", []):
        sc = c.get("securityContext", {})
        if sc.get("allowPrivilegeEscalation") is not False: errors.append(f"alloy/{c['name']}: allowPrivilegeEscalation must be false")
        if sc.get("readOnlyRootFilesystem") is not True: errors.append(f"alloy/{c['name']}: readOnlyRootFilesystem must be true")
        if sc.get("capabilities", {}).get("drop") != ["ALL"]: errors.append(f"alloy/{c['name']}: capabilities.drop must be [ALL]")
        if sc.get("privileged"): errors.append(f"alloy/{c['name']}: privileged")
        if not c.get("resources", {}).get("limits", {}).get("memory"): errors.append(f"alloy/{c['name']}: memory limit missing")
        if not re.search(r":v?\d[^@]*@sha256:[0-9a-f]{64}$", c["image"]): errors.append(f"alloy/{c['name']}: image must be pinned tag@digest")

# RBAC: namespaced, read-only, pods and pods/log only, nothing cluster-wide.
if by("ClusterRole") or by("ClusterRoleBinding"):
    errors.append("alloy.yaml: no ClusterRole/ClusterRoleBinding expected (namespaced Roles in prod and preprod)")
roles = by("Role")
if sorted(r["metadata"]["namespace"] for r in roles) != ["preprod", "prod"]:
    errors.append("alloy.yaml: Roles must exist in exactly prod and preprod")
for r in roles:
    for rule in r["rules"]:
        res = set(rule.get("resources", []))
        if not res <= {"pods", "pods/log"}: errors.append(f"Role {r['metadata']['namespace']}: resources beyond pods, pods/log: {sorted(res)}")
        if "secrets" in res or "*" in res: errors.append(f"Role {r['metadata']['namespace']}: secrets or wildcard resource")
        if not set(rule.get("verbs", [])) <= {"get", "list", "watch"}: errors.append(f"Role {r['metadata']['namespace']}: a write or wildcard verb")
        if rule.get("apiGroups") != [""]: errors.append(f"Role {r['metadata']['namespace']}: apiGroups must be core only")

# NetworkPolicy exists for Alloy and Loki accepts it.
nps = {d["metadata"]["name"]: d for d in by("NetworkPolicy")}
if "alloy" not in nps: errors.append("alloy.yaml: NetworkPolicy alloy missing")
if "loki-from-alloy" not in nps: errors.append("alloy.yaml: NetworkPolicy loki-from-alloy missing")
for b in nps.get("alloy", {}).get("spec", {}).get("egress", []):
    for to in b.get("to", []):
        if to.get("ipBlock", {}).get("cidr") == "0.0.0.0/0": errors.append("alloy egress: 0.0.0.0/0 is too wide")

# Config: scoped, labelled, redacting. Python's re is close enough to RE2 for these.
cm = [d for d in by("ConfigMap") if d["metadata"]["name"] == "alloy"][0]["data"]["config.alloy"]
if 'names         = ["prod", "preprod"]' not in cm: errors.append("alloy config: namespaces must be exactly prod, preprod")
if "/loki/api/v1/push" not in cm: errors.append("alloy config: push path /loki/api/v1/push missing")
if 'values = ["namespace", "app", "pod", "container"]' not in cm: errors.append("alloy config: label_keep allowlist missing")
exprs = re.findall(r"expression\s*=\s*`([^`]*)`\s*(?:replace\s*=\s*\"([^\"]*)\")?", cm)
drop = [e for e, r in exprs if not r]
reps = [(e, r) for e, r in exprs if r]
def scrub(line):
    if any(re.search(e, line) for e in drop):
        return None
    for e, r in reps:
        line = re.sub(e, lambda m: m.group(0).replace(m.group(1), r) if m.groups() and m.group(1) else m.group(0), line)
    return line
for line in ['kube-probe/1.34 "GET /health/ready HTTP/1.1" 200', '{"url":"/metrics","status":200}', 'GET /health 200', '"GET /health?x=1 HTTP/1.1"']:
    if scrub(line) is not None: errors.append(f"probe line not dropped: {line}")
for line in ['GET /api/content 200', '{"url":"/api/healthcheck-notes"}']:
    if scrub(line) is None: errors.append(f"normal line dropped: {line}")
secrets = {
  "jane.doe+x@example.co.uk": 'contact from jane.doe+x@example.co.uk failed',
  "abcDEF123456": 'Authorization: Bearer abcDEF123456',
  "s3cr3tvalue": 'GET /api/x?api_key=s3cr3tvalue&page=2',
  "placeholder": 'url=/cb?access_token=placeholder',
  "sessionid=deadbeef": 'Cookie: sessionid=deadbeef; theme=dark',
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig": 'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig in body',
  "Basic dXNlcjpwYXNz": '{"authorization":"Basic dXNlcjpwYXNz"}',
}
for secret, line in secrets.items():
    out = scrub(line)
    if out is None or secret in out or "[" not in out:
        errors.append(f"not redacted ({secret!r}): {out!r}")
if "page=2" not in (scrub('GET /api/x?api_key=s3cr3tvalue&page=2') or ""): errors.append("redaction ate the rest of the query string")

if errors:
    print("\n".join("FAIL " + e for e in errors))
    sys.exit(1)
print("ok   alloy: restricted-compatible, read-only pods/log RBAC in prod+preprod, NetworkPolicies, redaction samples")
PY

# 2 + 4: promtool and amtool, local or from the pinned images.
run_tool() { # run_tool <promtool|amtool> args...  (files live in $work, mounted at /w)
  local tool=$1; shift
  if command -v "$tool" >/dev/null 2>&1; then
    (cd "$work" && "$tool" "$@")
  elif command -v docker >/dev/null 2>&1; then
    local image=$PROMETHEUS_IMAGE
    [ "$tool" = amtool ] && image=$ALERTMANAGER_IMAGE
    docker run --rm --entrypoint "$tool" -v "$work:/w:ro" -v "$PWD/tests:/t:ro" -w /w "$image" "$@"
  else
    echo "FAIL need $tool or docker" >&2
    return 127
  fi
}

shopt -s nullglob
rule_files=("$work"/rules-*.yml)
[ "${#rule_files[@]}" -gt 0 ] || { echo "FAIL no PrometheusRule extracted" >&2; exit 1; }
names=()
for f in "${rule_files[@]}"; do names+=("$(basename "$f")"); done
run_tool promtool check rules "${names[@]}"

cp tests/alerts-unit.yml "$work/alerts-unit.yml"
run_tool promtool test rules alerts-unit.yml

sed -e 's/__SMTP_HOST__/smtp.example.invalid/g' -e 's/__SMTP_PORT__/465/g' \
    -e 's/__SMTP_USER__/resend/g' -e 's/__SMTP_FROM__/alerts@example.invalid/g' \
    -e 's/__ALERT_TO__/ops@example.invalid/g' k8s/alertmanager.yaml.tmpl >"$work/alertmanager.yml"
run_tool amtool check-config alertmanager.yml

fail=0
route() { # route <expected receiver> label=value...
  local want=$1; shift
  local got
  got=$(run_tool amtool config routes test --config.file=alertmanager.yml "$@" | tr -d '\r')
  if [ "$got" = "$want" ]; then
    echo "ok   route $* -> $got"
  else
    echo "FAIL route $* -> '$got', want '$want'"
    fail=1
  fi
}
route email   alertname=NodeCPUHigh team=portfolio severity=critical
route email   alertname=NodeCPUHigh team=portfolio severity=warning
route email   alertname=PodNotReady team=portfolio severity=warning namespace=prod
route email   alertname=WindomTokenReuse team=windom severity=page
route email   alertname=WindomServerErrors team=windom severity=warning
route heartbeat   alertname=Watchdog severity=none
route null    alertname=KubeCPUOvercommit severity=warning
route heartbeat   alertname=Watchdog team=portfolio severity=warning
[ "$fail" = 0 ]
