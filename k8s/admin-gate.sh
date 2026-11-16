#!/usr/bin/env bash
#
# Applies prod's admin gate: renders k8s/admin-gate.yaml.tmpl with prod's OWN
# ADMIN_PROXY_SECRET and pipes it to `kubectl apply -f -`. The secret is read
# from portfolio-api-env and never touches disk, argv or the terminal.
#
#   ./k8s/admin-gate.sh        # run where kubectl reaches the OCI k3s
#
# Why a script and not `kubectl apply -f k8s/`: the template carries a
# placeholder, and applying it raw would stamp that publicly known string as
# the proof header (#23). The file is named .tmpl so kubectl skips it.
# Re-run after rotating ADMIN_PROXY_SECRET so the stamp matches the API.
# Apply k8s/portfolio.yaml first: it declares prod/strip-identity, which this
# Ingress names. Without it Traefik refuses the router (fails closed).
set -euo pipefail
NS=prod
NODE=free-arm
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if ! kubectl get node "$NODE" >/dev/null 2>&1; then
  echo "refusing: kubectl context '$(kubectl config current-context 2>/dev/null || echo none)' has no node '$NODE'; this is not the OCI cluster" >&2
  exit 1
fi
kubectl get namespace "$NS" >/dev/null

secret=$(kubectl -n "$NS" get secret portfolio-api-env -o jsonpath='{.data.ADMIN_PROXY_SECRET}' | base64 -d)
if [ -z "$secret" ]; then
  echo "portfolio-api-env in $NS has no ADMIN_PROXY_SECRET" >&2
  exit 1
fi

tmpl=$(<"$here/admin-gate.yaml.tmpl")
printf '%s\n' "${tmpl//__ADMIN_PROXY_SECRET__/$secret}" | kubectl apply -f -
unset secret tmpl
echo "prod admin gate applied: open https://admin.yehudabriskman.com"
