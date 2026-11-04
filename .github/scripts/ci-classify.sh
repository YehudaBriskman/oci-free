#!/usr/bin/env bash
# Which of CI's path-filtered jobs this event needs. Used by the `classify`
# job in .github/workflows/ci.yml; the `CI gate` job reads its answer back.
#
# Only the jobs that cost real minutes are filtered: Helm (chart downloads),
# OpenTofu (a ~100 MB provider) and the telemetry e2e (four images). Secrets,
# Shell, Manifests and Scripts take seconds and always run.
#
# The rule is "select whenever unsure", because a job skipped that should
# have run costs more than the minutes it saves:
#   - anything but a pull request (a push to main, a manual run): everything;
#   - a pull request whose diff git cannot produce: everything;
#   - a change to CI itself (.github/) or to the shared tool pins: everything.
#
# Inputs (env): EVENT_NAME, BASE_SHA, HEAD_SHA. Writes `helm`, `tofu` and
# `telemetry` (true/false) to $GITHUB_OUTPUT, or to stdout off a runner.
set -Eeuo pipefail

out() { echo "$1=$2" >>"${GITHUB_OUTPUT:-/dev/stdout}"; }
all() {
  echo "$1: running everything"
  out helm true
  out tofu true
  out telemetry true
  exit 0
}

[ "${EVENT_NAME:-}" = pull_request ] || all "event ${EVENT_NAME:-<none>}"

# Three dots: what the branch changed since it left the base, not what the
# base has gained since.
if ! files=$(git diff --name-only "${BASE_SHA:?}...${HEAD_SHA:?}" 2>/dev/null); then
  all "no diff for ${BASE_SHA}...${HEAD_SHA}"
fi
echo "changed files:"
printf '  %s\n' "$files"

pick() { # pick <ERE>: true if any changed path matches
  if grep -qE -- "$1" <<<"$files"; then echo true; else echo false; fi
}

if [ "$(pick '^\.github/')" = true ]; then
  all "CI itself changed"
fi

out helm "$(pick '^k8s/[^/]+-values\.yaml$|^tests/helm\.sh$')"
out tofu "$(pick '\.tf$|^\.terraform\.lock\.hcl$|^cloud-init\.yaml$|^terraform\.tfvars\.example$')"
out telemetry "$(pick '^k8s/(observability\.yaml|windom-alerts\.yaml|alertmanager\.yaml\.tmpl)$|^tests/telemetry-e2e\.sh$')"
