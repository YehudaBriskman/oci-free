#!/usr/bin/env bash
#
# Print the base64 kubeconfig for one of CI's accounts, ready to pipe into
# the site repository's secret for that environment (#16).
#
#   ./k8s/ci-kubeconfig.sh <preprod|prod|drift> [--duration <go-duration>]
#
#   preprod  ci-deploy in preprod -> KUBECONFIG_PREPROD, `preprod` environment
#   prod     ci-deploy in prod    -> KUBECONFIG_PROD, `production` environment
#   drift    ci-drift (read-only) -> KUBECONFIG_DRIFT, repository secret
#
#   kubectl apply -f k8s/ci-rollout-rbac.yaml       # once
#   R=YehudaBriskman/portfolio_site
#   ./k8s/ci-kubeconfig.sh preprod | gh secret set KUBECONFIG_PREPROD -R "$R" --env preprod
#   ./k8s/ci-kubeconfig.sh prod    | gh secret set KUBECONFIG_PROD    -R "$R" --env production
#   ./k8s/ci-kubeconfig.sh drift   | gh secret set KUBECONFIG_DRIFT   -R "$R"
#
# Run it yourself. The output is a working credential for this cluster, so it
# should go from your terminal into GitHub's secret store and nowhere else --
# not into a chat, a ticket, or a file that gets committed. Piped straight into
# `gh secret set` it never touches the screen.
#
# What each grants is in ci-rollout-rbac.yaml, and the header there says what
# `patch` on a Deployment really allows: the whole pod template, not just the
# image. A deploy token is worth what its namespace holds.
#
# Token lifetime:
#   default            the account's `*-token` Secret: never expires, revoked
#                      by deleting that Secret (the control plane re-mints it
#                      when ci-rollout-rbac.yaml is applied again). Rotate by
#                      deleting, re-applying, and re-running the line above.
#   --duration 2160h   a bound token from `kubectl create token`: expires on
#                      its own (the API server may cap the duration), and
#                      re-running the line above before then is the rotation.
#                      It cannot be revoked on its own -- only by deleting the
#                      ServiceAccount -- which is the trade for the expiry.
set -euo pipefail

usage() { echo "usage: $0 <preprod|prod|drift> [--duration <e.g. 2160h>]" >&2; exit 2; }

case "${1-}" in
  preprod) NS=preprod; SA=ci-deploy ;;
  prod)    NS=prod;    SA=ci-deploy ;;
  drift)   NS=prod;    SA=ci-drift ;;
  *) usage ;;
esac
ENV_NAME=$1
shift
DURATION=""
case "${1-}" in
  "") ;;
  --duration) [ -n "${2-}" ] || usage; DURATION=$2 ;;
  *) usage ;;
esac
SECRET="$SA-token"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need kubectl
need base64

# The wrong cluster is the likeliest mistake, and here it is a quiet one: a
# kubeconfig for whatever context was used last would be minted, piped into
# GitHub and only fail at the next deploy (tests/scripts.sh).
if ! kubectl get node free-arm >/dev/null 2>&1; then
  echo "refusing: kubectl context '$(kubectl config current-context 2>/dev/null || echo none)' has no node 'free-arm'; this is not the OCI cluster" >&2
  exit 1
fi

# The server the *current* context talks to. If that is a tailnet address, the
# runner reaches it over Tailscale -- which is the whole reason the deploy job
# joins the tailnet before using this.
SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')
if [ -n "$DURATION" ]; then
  TOKEN=$(kubectl -n "$NS" create token "$SA" --duration "$DURATION")
  echo "minted a $DURATION token for $NS/$SA; set a reminder to re-run this before it lapses" >&2
else
  TOKEN=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)
fi

if [ -z "${CA:-}" ] || [ -z "${TOKEN:-}" ]; then
  echo "no token on $NS/$SECRET yet -- apply k8s/ci-rollout-rbac.yaml and retry" >&2
  exit 1
fi

# The context's namespace is the environment's own, so a call that forgets
# `-n` lands where the token can act rather than in a namespace it cannot.
# The drift reader spans both and passes `-n` on every call.
cat <<EOF | base64 -w0
apiVersion: v1
kind: Config
clusters:
  - name: oci
    cluster: {server: ${SERVER}, certificate-authority-data: ${CA}}
contexts:
  - name: ci-${ENV_NAME}
    context: {cluster: oci, namespace: ${NS}, user: ${SA}}
current-context: ci-${ENV_NAME}
users:
  - name: ${SA}
    user: {token: ${TOKEN}}
EOF
# A newline for a terminal, none for a pipe into `gh secret set`.
[ -t 1 ] && echo
exit 0
