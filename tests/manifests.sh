#!/usr/bin/env bash
# Schema-checks every manifest under k8s/ with kubeconform, strict mode
# (an unknown field is an error, not something the API server would silently
# drop on apply).
#
#   tests/manifests.sh          # needs kubeconform on PATH (.github/scripts/tools.sh install kubeconform)
#
# Which files: k8s/*.yaml except Helm values (`*-values.yaml`: chart input,
# not objects, and tests/helm.sh renders them) and `*.tmpl` (not YAML until
# a script fills it in; the .tmpl suffix is what keeps `kubectl apply -f k8s/`
# away from it as well).
#
# Schemas, both pinned to a commit so the result does not move under us:
#   - core kinds: yannh/kubernetes-json-schema, at the Kubernetes minor k3s
#     runs. Without the pin kubeconform reads `master`.
#   - CRDs: datreeio/CRDs-catalog for the traefik.io, monitoring.coreos.com,
#     cert-manager.io and helm.cattle.io kinds these manifests use.
# A kind with no schema in either is an error (no -ignore-missing-schemas):
# a new CRD should be a decision here, not a silent skip.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

K8S_VERSION=1.34.1
K8S_SCHEMAS=86d045595d3f93b703bbf439cf9eb4bd6830d58f   # yannh/kubernetes-json-schema
CRD_CATALOG=6ab3493622cd387923a2d0da5234f53e80e1bd28   # datreeio/CRDs-catalog

files=()
for f in k8s/*.yaml; do
  case "$f" in
    *-values.yaml) ;;
    *) files+=("$f") ;;
  esac
done
[ "${#files[@]}" -gt 0 ] || { echo "no manifests found" >&2; exit 2; }

cache=${TMPDIR:-/tmp}/kubeconform-cache
mkdir -p "$cache"

# Template variables are kubeconform's, not the shell's.
# shellcheck disable=SC2016
kubeconform \
  -strict \
  -summary \
  -output text \
  -kubernetes-version "$K8S_VERSION" \
  -cache "$cache" \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMAS/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRD_CATALOG/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "${files[@]}"
