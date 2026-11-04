#!/usr/bin/env bash
#
# Makes the admin area usable on preprod. It creates the two admin-gate
# Middlewares and sets the Ingress's middleware chain, and NOTHING else:
#
#   strip-identity -> github-auth -> inject-proxy-secret -> noindex
#
#   ./k8s/preprod-admin-gate.sh        # run where kubectl reaches the OCI k3s
#
# It deliberately does not `kubectl apply -f portfolio-preprod.yaml`. That
# manifest pins web and api to `:latest`, while CI deploys by digest, so a
# full apply silently swaps preprod back to the last release (it did, on
# 2026-11-04; #25 tracks pinning). The manifest stays the source of truth for
# the Ingress annotation; this script applies only that one field.
#
# `inject-proxy-secret` carries preprod's OWN ADMIN_PROXY_SECRET, read from
# portfolio-api-env and piped to `kubectl apply -f -`: never on disk, argv or
# the terminal. Re-running is safe. After `preprod-secrets.sh --rotate`, run
# this again so the stamp matches the API.
set -euo pipefail
NS=preprod
NODE=free-arm
CHAIN="preprod-strip-identity@kubernetescrd,preprod-github-auth@kubernetescrd,preprod-inject-proxy-secret@kubernetescrd,preprod-noindex@kubernetescrd"

# The wrong cluster is the likeliest mistake: kubectl's current context is
# whatever was used last. Refuse anything that is not the OCI node.
if ! kubectl get node "$NODE" >/dev/null 2>&1; then
  echo "refusing: kubectl context '$(kubectl config current-context 2>/dev/null || echo none)' has no node '$NODE'; this is not the OCI cluster" >&2
  exit 1
fi
kubectl get namespace "$NS" >/dev/null

secret=$(kubectl -n "$NS" get secret portfolio-api-env -o jsonpath='{.data.ADMIN_PROXY_SECRET}' | base64 -d)
if [ -z "$secret" ]; then
  echo "portfolio-api-env in $NS has no ADMIN_PROXY_SECRET; run ./k8s/preprod-secrets.sh first" >&2
  exit 1
fi

kubectl apply -f - <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: strip-identity, namespace: $NS}
spec:
  headers:
    customRequestHeaders:
      X-Auth-Request-User: ""
      X-Auth-Request-Email: ""
      X-Admin-Proxy-Secret: ""
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: inject-proxy-secret, namespace: $NS}
spec:
  headers:
    customRequestHeaders:
      X-Admin-Proxy-Secret: "$secret"
YAML
unset secret

kubectl -n "$NS" annotate ingress portfolio --overwrite \
  "traefik.ingress.kubernetes.io/router.middlewares=$CHAIN"
echo "preprod admin gate applied (images untouched): open https://preprod.yehudabriskman.com/admin"
