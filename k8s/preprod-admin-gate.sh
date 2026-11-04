#!/usr/bin/env bash
#
# Makes the admin area usable on preprod: renders the `inject-proxy-secret`
# Middleware from preprod's OWN ADMIN_PROXY_SECRET (in portfolio-api-env,
# written by preprod-secrets.sh), then applies portfolio-preprod.yaml, whose
# Ingress runs strip-identity -> github-auth -> inject-proxy-secret -> noindex.
#
#   ./k8s/preprod-admin-gate.sh
#
# The secret never touches disk, argv or the terminal: it is read from the
# cluster and piped to `kubectl apply -f -`. Re-running is safe. After
# `preprod-secrets.sh --rotate`, run this again so the stamp matches the API.
set -euo pipefail
NS=preprod
HERE=$(cd "$(dirname "$0")" && pwd)

secret=$(kubectl -n "$NS" get secret portfolio-api-env -o jsonpath='{.data.ADMIN_PROXY_SECRET}' | base64 -d)
if [ -z "$secret" ]; then
  echo "portfolio-api-env in $NS has no ADMIN_PROXY_SECRET; run ./k8s/preprod-secrets.sh first" >&2
  exit 1
fi

kubectl apply -f - <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: inject-proxy-secret, namespace: $NS}
spec:
  headers:
    customRequestHeaders:
      X-Admin-Proxy-Secret: "$secret"
YAML
unset secret

kubectl apply -f "$HERE/portfolio-preprod.yaml"
echo "preprod admin gate applied: open https://preprod.yehudabriskman.com/admin"
