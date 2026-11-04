#!/usr/bin/env bash
#
# Switches WindoM's telemetry on. It reads the ingest token from the cluster
# and sets the three standard OTel variables on the Fly app in one
# `secrets import`, which means one restart. The token goes ssh -> pipe ->
# flyctl's stdin. It never lands in argv, on disk or on the terminal.
#
#   ./k8s/otel-token-to-fly.sh        # from a machine with flyctl logged in
#
# Run it again after `telemetry-secrets.sh --rotate-token`. Until it is run,
# WindoM sends nothing (unset means off) and the WindomSilent alert fires.
set -euo pipefail
OCI_SSH=${OCI_SSH:-ubuntu@100.79.242.82}   # the node, over Tailscale SSH
APP=${FLY_APP:-windom-api}

tok=$(ssh -T "$OCI_SSH" \
  "sudo k3s kubectl -n observability get secret otel-ingest-token -o jsonpath='{.data.token}'" | base64 -d)
if [ "${#tok}" -lt 32 ]; then
  echo "refusing: no ingest token in the cluster; run telemetry-secrets.sh there first" >&2
  exit 1
fi

# printf is a shell builtin, so the token is not visible in /proc either.
printf 'OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.yehudabriskman.com\nOTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%%20%s\nOTEL_SERVICE_NAME=windom-api\n' "$tok" \
  | flyctl secrets import -a "$APP"
unset tok
echo "set on Fly app $APP; it restarts and starts sending."
