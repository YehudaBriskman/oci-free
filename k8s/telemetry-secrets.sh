#!/usr/bin/env bash
#
# Creates the Secrets that #14's telemetry needs. Nothing secret is ever on
# disk, in argv or printed:
#
#   observability/otel-ingest-token   the bearer token Fly sends (openssl rand)
#   monitoring/alertmanager-smtp      SMTP password (Resend), copied from prod's
#                                     portfolio-api-env (the site already mails
#                                     with it), mounted as a file by Alertmanager
#   monitoring/alertmanager-config    alertmanager.yaml.tmpl with host, port,
#                                     user, sender and recipient filled in
#                                     (none of them is secret). Recipient:
#                                     $ALERT_TO, else CONTACT_TO from the same
#                                     Secret.
#
#   ./k8s/telemetry-secrets.sh                 # run where kubectl reaches the OCI k3s
#   ./k8s/telemetry-secrets.sh --rotate-token  # new ingest token, then re-run
#                                              # otel-token-to-fly.sh
#
# Run it after `kubectl apply -f k8s/observability.yaml` (the namespace) and
# BEFORE the kube-prometheus-stack helm upgrade, whose values point
# Alertmanager at alertmanager-config.
#
# Writes use `apply --server-side`, so the values do not end up in a
# last-applied-configuration annotation as well (see #26).
set -euo pipefail
NODE=free-arm
HERE=$(cd "$(dirname "$0")" && pwd)
ROTATE=0
case "${1:-}" in
  --rotate-token) ROTATE=1 ;;
  "") ;;
  *) echo "usage: $0 [--rotate-token]" >&2; exit 2 ;;
esac

if ! kubectl get node "$NODE" >/dev/null 2>&1; then
  echo "refusing: kubectl context '$(kubectl config current-context 2>/dev/null || echo none)' has no node '$NODE'; this is not the OCI cluster" >&2
  exit 1
fi
kubectl get namespace observability monitoring prod >/dev/null

put() {  # put <namespace> <secret> <key>  -- value on stdin
  kubectl -n "$1" create secret generic "$2" --from-file="$3"=/dev/stdin --dry-run=client -o yaml \
    | kubectl apply --server-side --field-manager=telemetry-secrets --force-conflicts -f - >/dev/null
  echo "  $1/$2 written"
}

# 1. The ingest token. Created once; replaced only on --rotate-token, because
#    replacing it breaks WindoM until Fly has the new one.
if [ "$ROTATE" = 1 ] || ! kubectl -n observability get secret otel-ingest-token >/dev/null 2>&1; then
  openssl rand -hex 32 | tr -d '\n' | put observability otel-ingest-token token
  kubectl -n observability rollout restart deployment/otel-collector >/dev/null 2>&1 || true
  echo "  new ingest token: push it to Fly with ./k8s/otel-token-to-fly.sh (from your machine)"
else
  echo "  observability/otel-ingest-token exists, kept (use --rotate-token to replace)"
fi

# 2. SMTP. The site's own mail credentials (Resend), read and re-written inside
#    the cluster. Strip quotes and spaces: --from-env-file keeps them (README).
#    Values are never printed, only the name of what is missing.
field() {
  kubectl -n prod get secret portfolio-api-env -o jsonpath="{.data.$1}" | base64 -d | tr -d '"'"'"'[:space:]'
}
addr() {  # `Name <addr>` (spaces already stripped: Name<addr>) -> addr
  sed -E 's/^.*<([^>]*)>.*$/\1/'
}
missing=""
host=$(field SMTP_HOST); port=$(field SMTP_PORT); user=$(field SMTP_USER)
from=$(field MAIL_FROM | addr)
to=${ALERT_TO:-$(field CONTACT_TO | addr)}
[ -n "$host" ] || missing="$missing SMTP_HOST"
case "$port" in ''|*[!0-9]*) missing="$missing SMTP_PORT" ;; esac
[ -n "$user" ] || missing="$missing SMTP_USER"
case "$from" in *@*) ;; *) missing="$missing MAIL_FROM" ;; esac
case "$to" in *@*) ;; *) missing="$missing ALERT_TO/CONTACT_TO" ;; esac
[ "$(field SMTP_PASS | wc -c)" -ge 8 ] || missing="$missing SMTP_PASS"
if [ -n "$missing" ]; then
  echo "refusing: prod portfolio-api-env is missing or has unusable:$missing" >&2; exit 1
fi
field SMTP_PASS | put monitoring alertmanager-smtp password
sed -e "s|__SMTP_HOST__|$host|g" -e "s|__SMTP_PORT__|$port|g" -e "s|__SMTP_USER__|$user|g" \
    -e "s|__SMTP_FROM__|$from|g" -e "s|__ALERT_TO__|$to|g" "$HERE/alertmanager.yaml.tmpl" \
  | put monitoring alertmanager-config alertmanager.yaml

echo "done. Alerts go out through the site's SMTP account."
