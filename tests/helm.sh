#!/usr/bin/env bash
# Renders each Helm values file under k8s/ against the chart version the
# cluster runs (README, "Helm releases"), so a values key the chart does not
# understand, or a template it no longer renders, fails here rather than at
# `helm upgrade` time on the node.
#
#   tests/helm.sh            # needs helm on PATH (.github/scripts/tools.sh install helm)
#
# Each chart archive is checked against the sha256 recorded at the pin: a
# chart repository can re-publish a version, and this should notice.
#
# Not here, on purpose:
#   - traefik: k3s installs it from its bundled HelmChart (40.1.4+up40.1.0);
#     its only input in this repo is k8s/traefik-config.yaml, a
#     HelmChartConfig that tests/manifests.sh schema-checks.
#   - cert-manager v1.21.1: installed with chart defaults; there is no values
#     file to render.
#
# Bumping a chart: change the version AND the digest below, in the same
# commit as the README table and the upgrade.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

KUBE_VERSION=1.34.1   # the k3s minor; some charts gate templates on it

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# render <name> <chart-ref> <version> <sha256> <release> <namespace> <values> [repo-url]
render() {
  local name=$1 ref=$2 version=$3 sum=$4 release=$5 ns=$6 values=$7 repo=${8:-}
  local dir="$work/$name" tgz
  mkdir -p "$dir"
  if [ -n "$repo" ]; then
    helm pull "$ref" --repo "$repo" --version "$version" -d "$dir" >/dev/null
  else
    helm pull "$ref" --version "$version" -d "$dir" >/dev/null
  fi
  tgz=$(echo "$dir"/*.tgz)
  if ! echo "$sum  $tgz" | sha256sum -c --quiet - >/dev/null 2>&1; then
    echo "FAIL $name $version: chart archive digest changed (want $sum, got $(sha256sum "$tgz" | cut -d' ' -f1))"
    fail=1
    return
  fi
  if helm template "$release" "$tgz" -n "$ns" -f "$values" --kube-version "$KUBE_VERSION" >"$dir/out.yaml" 2>"$dir/err"; then
    echo "ok   $name $version with $values ($(grep -c '^kind:' "$dir/out.yaml") objects)"
  else
    echo "FAIL $name $version with $values:"
    sed 's/^/     /' "$dir/err"
    fail=1
  fi
}

render kube-prometheus-stack kube-prometheus-stack 89.2.2 \
  05483f2ca0b047880e39869927ed7d313a365e7cd030e8fa782a755e44514d8f \
  kube-prometheus-stack monitoring k8s/monitoring-values.yaml \
  https://prometheus-community.github.io/helm-charts
render forgejo oci://code.forgejo.org/forgejo-helm/forgejo 17.1.5 \
  3d40e833748e5c92855c7f919f689ba526eeec72a08386e797d65905f9a3ae29 \
  forgejo forgejo k8s/forgejo-values.yaml
render couchdb couchdb 4.6.3 \
  33a028ac76293c039d382d507800f4510dc1a3ad8050f1d43f2e61b2e7138864 \
  couchdb obsidian k8s/couchdb-values.yaml \
  https://apache.github.io/couchdb-helm

# Every values file has a render above: a new one must be added, not skipped.
for v in k8s/*-values.yaml; do
  case "$v" in
    k8s/monitoring-values.yaml | k8s/forgejo-values.yaml | k8s/couchdb-values.yaml) ;;
    *) echo "FAIL $v has no chart in tests/helm.sh"; fail=1 ;;
  esac
done

exit "$fail"
