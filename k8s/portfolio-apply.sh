#!/usr/bin/env bash
#
# Applies the portfolio manifest for one namespace without touching the images
# CI deployed (#25).
#
#   ./k8s/portfolio-apply.sh prod       # k8s/portfolio.yaml
#   ./k8s/portfolio-apply.sh preprod    # k8s/portfolio-preprod.yaml
#
# The manifests carry no `image:` for `web` and `api`; CI owns that field. Two
# things a plain `kubectl apply -f` cannot do then, and this script does:
#
# 1. CREATE a missing Deployment. The API server refuses one without an image,
#    so a missing `web`/`api` is created at `:latest` (the last release, moved
#    only after a passing prod deploy) and the manifest is applied over it.
#    CI's next deploy replaces `:latest` with a digest. Preprod's next deploy
#    is the next push to `main`; re-run the last CI deploy to get it sooner.
# 2. MIGRATE a Deployment last applied from the old manifest, once. Its
#    last-applied annotation still lists `image: ...:latest`, so a plain apply
#    of the new file tries to delete the field and is refused. Dropping that
#    annotation lets the apply write a new one without `image`.
#
# After it has run once per namespace, `kubectl apply -f` of the manifest is
# safe and leaves the image alone. Re-running this script is also safe.
set -euo pipefail

NS=${1:-}
case "$NS" in
  prod)    FILE=portfolio.yaml ;;
  preprod) FILE=portfolio-preprod.yaml ;;
  *) echo "usage: $0 prod|preprod" >&2; exit 2 ;;
esac
HERE=$(cd "$(dirname "$0")" && pwd)
NODE=free-arm
IMAGE_BASE=ghcr.io/yehudabriskman/portfolio_site

# Same guard as preprod-admin-gate.sh: kubectl's current context is whatever
# was used last, and this creates things.
if ! kubectl get node "$NODE" >/dev/null 2>&1; then
  echo "refusing: kubectl context '$(kubectl config current-context 2>/dev/null || echo none)' has no node '$NODE'; this is not the OCI cluster" >&2
  exit 1
fi

if [ -z "$(kubectl get namespace "$NS" --ignore-not-found -o name)" ]; then
  kubectl create namespace "$NS"
fi

for d in web api; do
  if [ -z "$(kubectl -n "$NS" get deploy "$d" --ignore-not-found -o name)" ]; then
    # `create deployment` names the container after the image (`web`, `api`)
    # and labels it app=<name>, which is what the manifest's selector expects.
    kubectl -n "$NS" create deployment "$d" --image="$IMAGE_BASE/$d:latest"
    continue
  fi
  last=$(kubectl -n "$NS" get deploy "$d" \
    -o 'jsonpath={.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}')
  if printf '%s' "$last" | grep -q '"image":'; then
    echo "$NS/$d: dropping a last-applied annotation that still owns the image"
    kubectl -n "$NS" annotate deploy "$d" kubectl.kubernetes.io/last-applied-configuration-
  fi
done

kubectl apply -f "$HERE/$FILE"

echo "running in $NS (set by CI, untouched by this apply):"
kubectl -n "$NS" get deploy web api \
  -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
