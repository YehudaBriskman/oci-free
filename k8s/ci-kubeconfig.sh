#!/usr/bin/env bash
#
# Print the base64 kubeconfig for the `ci-rollout` ServiceAccount, ready to
# paste into the site repository's KUBECONFIG_B64 secret.
#
#   kubectl apply -f k8s/ci-rollout-rbac.yaml     # once
#   ./k8s/ci-kubeconfig.sh | wl-copy              # or pbcopy, or > a file
#
# Run it yourself. The output is a working credential for this cluster, so it
# should go from your terminal into GitHub's secret store and nowhere else —
# not into a chat, a ticket, or a file that gets committed.
#
# What it grants is in ci-rollout-rbac.yaml: get/patch/watch on the `web` and
# `api` Deployments in `prod` and in `preprod`, and read on the ReplicaSets and
# Pods behind them. Nothing else, nowhere else. Revoke with
# `kubectl -n prod delete secret ci-rollout-token`.
#
# One token covers both namespaces because preprod binds this same account, so
# adding preprod did not add a credential to rotate. The context below still
# defaults to `prod`; every call in the pipeline passes `-n` explicitly, which
# is what makes one kubeconfig serve two environments.
set -euo pipefail

NS=prod
SA=ci-rollout
SECRET=ci-rollout-token

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need kubectl
need base64

# The server the *current* context talks to. If that is a tailnet address, the
# runner reaches it over Tailscale — which is the whole reason the deploy job
# joins the tailnet before using this.
SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')
TOKEN=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)

if [ -z "${CA:-}" ] || [ -z "${TOKEN:-}" ]; then
  echo "no token on $SECRET yet — apply k8s/ci-rollout-rbac.yaml and retry" >&2
  exit 1
fi

cat <<EOF | base64 -w0
apiVersion: v1
kind: Config
clusters:
  - name: prod
    cluster: {server: ${SERVER}, certificate-authority-data: ${CA}}
contexts:
  - name: ci
    context: {cluster: prod, namespace: ${NS}, user: ${SA}}
current-context: ci
users:
  - name: ${SA}
    user: {token: ${TOKEN}}
EOF
echo
