#!/usr/bin/env bash
# Behaviour tests for the operator scripts, with kubectl, ssh, rsync and flyctl
# replaced by stubs (tests/stubs/) that record every call. Nothing here can
# reach a cluster: the stubs are first on PATH and answer from env variables.
#
#   tests/scripts.sh            # plain bash; needs openssl and base64
#
# What it holds:
#   1. Every script that writes to the cluster refuses, before writing
#      anything, when the current context has no node `free-arm`.
#   2. portfolio-apply.sh drops a last-applied annotation only when it still
#      owns the image (`"image":`), and creates a missing Deployment.
#   3. telemetry-secrets.sh and preprod-secrets.sh never put a secret on argv:
#      values reach kubectl on stdin (`--from-file=k=/dev/stdin`,
#      `--from-env-file=/dev/stdin`, `apply -f -`).
#   4. otel-token-to-fly.sh refuses a short or missing token and hands Fly a
#      good one on stdin only.
# No -e: a failing assertion is counted and reported, not fatal.
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD

pass=0
fail=0
failed=()

base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT
bin=$base/bin
mkdir -p "$bin"
cp tests/stubs/kubectl "$bin/kubectl"
for t in ssh rsync flyctl; do cp tests/stubs/recorder "$bin/$t"; done
export PATH="$bin:$PATH"

# ------------------------------------------------------------ harness -------
# Each test runs in a subshell with a fresh STUB_DIR, so stub settings and
# env from one test cannot leak into the next.
fresh() {
  STUB_DIR=$(mktemp -d "$base/run.XXXXXX")
  export STUB_DIR
  : >"$STUB_DIR/calls"
}
# run <script> [args...]: sets RC, OUT, ERR.
run() {
  "$ROOT/$1" "${@:2}" >"$STUB_DIR/out" 2>"$STUB_DIR/err" </dev/null
  RC=$?
  OUT=$(cat "$STUB_DIR/out")
  ERR=$(cat "$STUB_DIR/err")
}
calls() { cat "$STUB_DIR/calls"; }
# The line number of the first call matching an ERE; its stdin is stdin.<n>.
call_no() { grep -nE -- "$1" "$STUB_DIR/calls" | head -1 | cut -d: -f1; }
stdin_of() { local n; n=$(call_no "$1"); [ -n "$n" ] && cat "$STUB_DIR/stdin.$n" 2>/dev/null; }

check() { # check <description> <command...>
  if "${@:2}"; then return 0; fi
  echo "      not: $1"
  return 1
}
called() { grep -qE -- "$1" "$STUB_DIR/calls"; }
not_called() { ! grep -qE -- "$1" "$STUB_DIR/calls"; }
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

t() { # t <name> <function>
  local name=$1 rc
  ( fresh; "$2" )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   $name"; pass=$((pass + 1))
  else
    echo "FAIL $name"; fail=$((fail + 1)); failed+=("$name")
    if [ -n "${VERBOSE:-}" ]; then echo "      (see above)"; fi
  fi
}

b64() { printf '%s' "$1" | base64 -w0; }

# Any kubectl verb that changes the cluster, or a call that leaves the machine.
WRITES='^(kubectl( -n [^ ]+)? (apply|create|annotate|patch|rollout|delete|label|set|replace|scale|edit)|ssh |rsync |flyctl )'

# ------------------------------------------------------------ 1. guard ------
# Everything the scripts look for exists except the node, so the only thing
# that can stop them is the guard.
guard_env() {
  export STUB_NODE=absent
  export STUB_NAMESPACES="prod preprod observability monitoring"
  export STUB_DEPLOYS="prod/web prod/api"
  export STUB_SECRETS="prod/portfolio-api-env preprod/portfolio-api-env observability/otel-ingest-token prod/ci-deploy-token"
  export STUB_DATA_preprod_portfolio_api_env_ADMIN_PROXY_SECRET
  STUB_DATA_preprod_portfolio_api_env_ADMIN_PROXY_SECRET=$(b64 x)
}
refuses() { # refuses <script> [args]
  guard_env
  run "$@"
  check "exit non-zero (got $RC)" [ "$RC" -ne 0 ] &&
    check "say why on stderr (got: $ERR)" contains "$ERR" "refusing" &&
    check "write nothing (calls: $(calls | tr '\n' ';'))" not_called "$WRITES" &&
    check "print nothing on stdout (got: $OUT)" [ -z "$OUT" ]
}
# And with the node present the same script gets past the guard, so the test
# above is not passing because the script fails for some other reason.
proceeds() {
  guard_env
  export STUB_NODE=present
  run "$@"
  check "get past the guard with node free-arm (rc $RC, calls: $(calls | tr '\n' ';'))" \
    [ "$(wc -l <"$STUB_DIR/calls")" -gt 1 ]
}

for s in "k8s/portfolio-apply.sh prod" "k8s/portfolio-apply.sh preprod" "k8s/telemetry-secrets.sh" \
  "k8s/preprod-secrets.sh" "k8s/preprod-admin-gate.sh" "k8s/ci-kubeconfig.sh prod" \
  "deploy-portfolio.sh api"; do
  # shellcheck disable=SC2086 # script and its argument
  eval "g_refuse() { refuses $s; }; g_proceed() { proceeds $s; }"
  t "guard: $s refuses without node free-arm" g_refuse
  t "guard: $s proceeds with node free-arm" g_proceed
done

# Every script that runs kubectl at all is in the list above, or says here why
# not. A new cluster-writing script fails this until it has a guard and a test.
t_inventory() {
  local f bad=0
  while IFS= read -r f; do
    case "$f" in
      k8s/portfolio-apply.sh | k8s/telemetry-secrets.sh | k8s/preprod-secrets.sh | \
        k8s/preprod-admin-gate.sh | k8s/ci-kubeconfig.sh | deploy-portfolio.sh) ;;
      # Runs kubectl on the node over ssh, read-only (`get secret`).
      k8s/otel-token-to-fly.sh) ;;
      *) echo "      $f runs kubectl and is not covered by the guard tests"; bad=1 ;;
    esac
    if [ "$f" != k8s/otel-token-to-fly.sh ] && ! grep -q 'kubectl get node' "$f"; then
      echo "      $f has no free-arm guard"; bad=1
    fi
  done < <(grep -lE '^[^#]*kubectl ' -- *.sh k8s/*.sh)
  [ "$bad" = 0 ]
}
t "guard: every kubectl script is covered" t_inventory

# ------------------------------------------------------------ 2. portfolio-apply
pa_env() {
  export STUB_NODE=present
  export STUB_NAMESPACES="prod preprod"
}
t_pa_migrates_only_image_owner() {
  pa_env
  export STUB_DEPLOYS="prod/web prod/api"
  export STUB_LAST_prod_web='{"apiVersion":"apps/v1","kind":"Deployment","spec":{"template":{"spec":{"containers":[{"name":"web","image":"ghcr.io/yehudabriskman/portfolio_site/web:latest"}]}}}}'
  # Mentions images, but does not own the field: must be left alone.
  export STUB_LAST_prod_api='{"apiVersion":"apps/v1","kind":"Deployment","spec":{"template":{"spec":{"containers":[{"name":"api","imagePullPolicy":"Always"}]}}}}'
  run k8s/portfolio-apply.sh prod
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "drop web's annotation" called '^kubectl -n prod annotate deploy web kubectl\.kubernetes\.io/last-applied-configuration-$' &&
    check "keep api's annotation" not_called 'annotate deploy api' &&
    check "create nothing" not_called ' create ' &&
    check "apply portfolio.yaml" called "^kubectl apply -f $ROOT/k8s/portfolio\.yaml$"
}
t "portfolio-apply: drops last-applied only when it has \"image\":" t_pa_migrates_only_image_owner

t_pa_no_annotation() {
  pa_env
  export STUB_DEPLOYS="prod/web prod/api"
  run k8s/portfolio-apply.sh prod
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "annotate nothing" not_called ' annotate ' &&
    check "apply portfolio.yaml" called "apply -f $ROOT/k8s/portfolio\.yaml$"
}
t "portfolio-apply: no last-applied, nothing dropped" t_pa_no_annotation

t_pa_creates_missing() {
  pa_env
  export STUB_NAMESPACES="prod"             # preprod is missing
  export STUB_DEPLOYS="preprod/web"         # api is missing
  run k8s/portfolio-apply.sh preprod
  local create apply
  create=$(call_no 'create deployment api')
  apply=$(call_no 'apply -f')
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "create the namespace" called '^kubectl create namespace preprod$' &&
    check "create api at :latest" called '^kubectl -n preprod create deployment api --image=ghcr\.io/yehudabriskman/portfolio_site/api:latest$' &&
    check "not re-create web" not_called 'create deployment web' &&
    check "apply portfolio-preprod.yaml" called "apply -f $ROOT/k8s/portfolio-preprod\.yaml$" &&
    check "create before apply" [ -n "$create" ] && [ -n "$apply" ] && [ "$create" -lt "$apply" ]
}
t "portfolio-apply: creates a missing namespace and Deployment" t_pa_creates_missing

t_pa_usage() {
  pa_env
  run k8s/portfolio-apply.sh staging
  check "exit 2 (rc $RC)" [ "$RC" -eq 2 ] && check "call nothing" [ ! -s "$STUB_DIR/calls" ]
}
t "portfolio-apply: an unknown namespace is a usage error" t_pa_usage

# ------------------------------------------------------------ 3. secrets ----
SMTP_PASS_SENTINEL="pass-sentinel-4e1f9a"
ts_env() {
  export STUB_NODE=present
  export STUB_NAMESPACES="observability monitoring prod"
  export STUB_SECRETS="prod/portfolio-api-env"
  # Quoted and padded, the way --from-env-file once stored them (README).
  STUB_DATA_prod_portfolio_api_env_SMTP_USER=$(b64 '"alerts@example.com" ')
  STUB_DATA_prod_portfolio_api_env_SMTP_PASS=$(b64 "'$SMTP_PASS_SENTINEL'
")
  export STUB_DATA_prod_portfolio_api_env_SMTP_USER STUB_DATA_prod_portfolio_api_env_SMTP_PASS
}
t_ts_stdin_only() {
  ts_env
  run k8s/telemetry-secrets.sh
  local token pw cfg
  token=$(stdin_of 'create secret generic otel-ingest-token')
  pw=$(stdin_of 'create secret generic alertmanager-smtp')
  cfg=$(stdin_of 'create secret generic alertmanager-config')
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "token via --from-file=token=/dev/stdin" called 'create secret generic otel-ingest-token --from-file=token=/dev/stdin' &&
    check "token is 64 hex chars on stdin (got ${#token})" grep -qxE '[0-9a-f]{64}' <<<"$token" &&
    check "token on no argv" not_called "$token" &&
    check "password via --from-file=password=/dev/stdin" called 'create secret generic alertmanager-smtp --from-file=password=/dev/stdin' &&
    check "password on stdin, quotes and spaces stripped (got '$pw')" [ "$pw" = "$SMTP_PASS_SENTINEL" ] &&
    check "password on no argv" not_called "$SMTP_PASS_SENTINEL" &&
    check "password not printed" lacks "$OUT$ERR" "$SMTP_PASS_SENTINEL" &&
    check "token not printed" lacks "$OUT$ERR" "$token" &&
    check "alertmanager config rendered with the address" contains "$cfg" "smtp_from: alerts@example.com" &&
    check "no placeholder left" lacks "$cfg" "__SMTP_USER__" &&
    check "every secret write is server-side apply from stdin" \
      [ "$(grep -c 'apply --server-side --field-manager=telemetry-secrets --force-conflicts -f -$' "$STUB_DIR/calls")" -eq 3 ] &&
    check "no client-side apply" not_called '^kubectl apply -f'
}
t "telemetry-secrets: token and password only on stdin" t_ts_stdin_only

t_ts_keeps_token() {
  ts_env
  export STUB_SECRETS="prod/portfolio-api-env observability/otel-ingest-token"
  run k8s/telemetry-secrets.sh
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "existing token kept" not_called 'otel-ingest-token --from-file'
}
t "telemetry-secrets: an existing token is kept without --rotate-token" t_ts_keeps_token

t_ts_no_pass() {
  ts_env
  STUB_DATA_prod_portfolio_api_env_SMTP_PASS=$(b64 '""')
  run k8s/telemetry-secrets.sh
  check "exit non-zero (rc $RC)" [ "$RC" -ne 0 ] &&
    check "no smtp secret written" not_called 'alertmanager-smtp'
}
t "telemetry-secrets: refuses an empty SMTP_PASS" t_ts_no_pass

t_ps_stdin_only() {
  export STUB_NODE=present STUB_NAMESPACES="preprod prod" STUB_SECRETS="prod/ghcr-pull"
  STUB_DATA_prod_ghcr_pull__dockerconfigjson=$(b64 '{"auths":{}}')
  export STUB_DATA_prod_ghcr_pull__dockerconfigjson
  # Made up at run time, so no token-shaped literal sits in the repository
  # for the secret scan to (rightly) flag.
  GITHUB_TOKEN="fake-pat-$(openssl rand -hex 8)"
  export GITHUB_TOKEN
  run k8s/preprod-secrets.sh
  local env couch
  env=$(stdin_of 'create secret generic portfolio-api-env')
  couch=$(stdin_of 'create secret generic preprod-couch')
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "GITHUB_TOKEN on stdin" contains "$env" "GITHUB_TOKEN=$GITHUB_TOKEN" &&
    check "GITHUB_TOKEN on no argv" not_called "$GITHUB_TOKEN" &&
    check "ADMIN_PROXY_SECRET generated on stdin" grep -qE '^ADMIN_PROXY_SECRET=[0-9a-f]{64}$' <<<"$env" &&
    check "ADMIN_PROXY_SECRET on no argv" not_called 'ADMIN_PROXY_SECRET' &&
    check "CouchDB password on stdin" grep -qE '^COUCHDB_PASSWORD=.{32}$' <<<"$couch" &&
    check "CouchDB password on no argv" not_called 'COUCHDB_PASSWORD' &&
    check "all sixteen-plus keys present" [ "$(grep -c '=' <<<"$env")" -eq 19 ]
}
t "preprod-secrets: generated secrets and GITHUB_TOKEN only on stdin" t_ps_stdin_only

t_gate_stdin_only() {
  export STUB_NODE=present STUB_NAMESPACES="preprod" STUB_SECRETS="preprod/portfolio-api-env"
  STUB_DATA_preprod_portfolio_api_env_ADMIN_PROXY_SECRET=$(b64 proxy-sentinel-77)
  export STUB_DATA_preprod_portfolio_api_env_ADMIN_PROXY_SECRET
  run k8s/preprod-admin-gate.sh
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "secret on stdin" contains "$(stdin_of 'apply -f -')" 'X-Admin-Proxy-Secret: "proxy-sentinel-77"' &&
    check "secret on no argv" not_called proxy-sentinel-77
}
t "preprod-admin-gate: the proxy secret only on stdin" t_gate_stdin_only

# ------------------------------------------------------------ 4. fly --------
t_fly_short() {
  export STUB_SSH_OUT
  STUB_SSH_OUT=$(b64 short-token)
  run k8s/otel-token-to-fly.sh
  check "exit 1 (rc $RC)" [ "$RC" -eq 1 ] &&
    check "say why" contains "$ERR" refusing &&
    check "flyctl not called" not_called '^flyctl'
}
t "otel-token-to-fly: refuses a short token" t_fly_short

t_fly_empty() {
  export STUB_SSH_OUT=""
  run k8s/otel-token-to-fly.sh
  check "exit 1 (rc $RC)" [ "$RC" -eq 1 ] && check "flyctl not called" not_called '^flyctl'
}
t "otel-token-to-fly: refuses a missing token" t_fly_empty

t_fly_ssh_fails() {
  export STUB_SSH_OUT="" STUB_SSH_RC=255
  run k8s/otel-token-to-fly.sh
  check "exit non-zero (rc $RC)" [ "$RC" -ne 0 ] && check "flyctl not called" not_called '^flyctl'
}
t "otel-token-to-fly: stops when ssh fails" t_fly_ssh_fails

t_fly_ok() {
  local tok
  tok=$(openssl rand -hex 32)
  export STUB_SSH_OUT
  STUB_SSH_OUT=$(b64 "$tok")
  run k8s/otel-token-to-fly.sh
  local in
  in=$(stdin_of '^flyctl secrets import')
  check "exit 0 (rc $RC: $ERR)" [ "$RC" -eq 0 ] &&
    check "one secrets import on windom-api" called '^flyctl secrets import -a windom-api$' &&
    check "token in the headers variable" contains "$in" "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20$tok" &&
    check "token on no argv" not_called "$tok" &&
    check "token not printed" lacks "$OUT$ERR" "$tok"
}
t "otel-token-to-fly: a good token reaches Fly on stdin only" t_fly_ok

echo
echo "scripts: $pass passed, $fail failed"
for f in "${failed[@]}"; do echo "  failed: $f"; done
[ "$fail" -eq 0 ]
