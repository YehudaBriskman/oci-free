#!/usr/bin/env bash
# Secret scanning of the commits CI is asked about. Run by the Secrets job in
# .github/workflows/ci.yml and weekly by .github/workflows/secret-scan.yml.
#
# Copied from YehudaBriskman/portfolio_site (.github/scripts/secret-scan.sh,
# its #206), same pin and same behaviour, so the two repositories answer the
# question the same way. Changed here: `install` also works off a runner (it
# falls back to a cache directory and does not need $GITHUB_PATH), so the
# scan can be run locally with the identical binary:
#
#   .github/scripts/secret-scan.sh install
#   PATH="$HOME/.cache/oci-free-tools/gitleaks:$PATH" MODE=full .github/scripts/secret-scan.sh scan
#
# This repository is private on GitHub Free, which has no secret scanning of
# its own and no branch protection: this script is the only automated check
# that a credential did not get committed.
#
#   secret-scan.sh install   the pinned gitleaks binary, checksum verified
#   secret-scan.sh range     print the `git log` range this event covers
#   secret-scan.sh scan      run gitleaks over that range
#
# WHICH COMMITS
#
#   pull request   base..head: every commit the branch adds, intermediate ones
#                  included. A secret committed and then deleted two commits
#                  later is still in the history the merge would publish.
#   push to main   before..after: the commits that push added. A force push or
#                  a new branch (no usable `before`) scans after's whole history.
#   MODE=full      every ref in the clone: the weekly full-history scan.
#   anything else  (a tag, a manual run) nothing new: a tag names a commit main
#                  already scanned. Said so, not silently skipped.
#
# Findings are printed REDACTED (`--redact`): the file, line, commit and rule,
# never the value. No report file is written or uploaded. A finding exits 3;
# any other failure is gitleaks itself failing, which is not "no secrets".
#
# Inputs are environment variables: EVENT_NAME, REF, BASE_SHA, HEAD_SHA,
# BEFORE, AFTER, MODE. gitleaks and git are called by name.
set -Eeuo pipefail

ZERO=0000000000000000000000000000000000000000

die() {
  echo "::error title=$1::$2" >&2
  exit 2
}

# An exact version, checked against the sha256 its release publishes, like
# actionlint. The binary, not gitleaks-action: the action needs a licence key
# for an organisation account and uploads a report artifact by default.
GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256_X64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
install() {
  local dir tgz="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  dir="${RUNNER_TEMP:-${XDG_CACHE_HOME:-$HOME/.cache}/oci-free-tools}/gitleaks"
  [ "${RUNNER_ARCH:-X64}" = X64 ] || die "No gitleaks for ${RUNNER_ARCH}" "secret-scan.sh pins the linux x64 build only"
  mkdir -p "$dir"
  curl -fsSLo "$dir/$tgz" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/$tgz"
  echo "$GITLEAKS_SHA256_X64  $dir/$tgz" | sha256sum -c -
  tar -xzf "$dir/$tgz" -C "$dir" gitleaks
  if [ -n "${GITHUB_PATH:-}" ]; then echo "$dir" >>"$GITHUB_PATH"; fi
  "$dir/gitleaks" version
}

is_commit() { [ -n "$1" ] && [ "$1" != "$ZERO" ] && git cat-file -e "$1^{commit}" 2>/dev/null; }

# Prints the log options, or nothing for "no new commits". A range whose
# ends are missing from the clone is an error, never a smaller scan.
range() {
  if [ "${MODE:-}" = full ]; then
    echo "--all"
    return
  fi
  case "${EVENT_NAME:-}" in
    pull_request)
      is_commit "${BASE_SHA:-}" || die "Secret scan: no base" "the pull request's base ${BASE_SHA:-<empty>} is not in the clone (fetch-depth: 0?)"
      is_commit "${HEAD_SHA:-}" || die "Secret scan: no head" "the pull request's head ${HEAD_SHA:-<empty>} is not in the clone"
      echo "$BASE_SHA..$HEAD_SHA"
      ;;
    push)
      if [ "${REF:-}" != refs/heads/main ]; then
        return 0
      fi
      is_commit "${AFTER:-}" || die "Secret scan: no commit" "the pushed commit ${AFTER:-<empty>} is not in the clone"
      if is_commit "${BEFORE:-}" && git merge-base --is-ancestor "$BEFORE" "$AFTER"; then
        echo "$BEFORE..$AFTER"
      else
        # A force push or a first push: nothing to subtract, so everything
        # reachable from what main now is.
        echo "$AFTER"
      fi
      ;;
    *) return 0 ;;
  esac
}

scan() {
  local opts n rc=0
  opts=$(range)
  if [ -z "$opts" ]; then
    echo "::notice title=Secret scan::No new commits for ${EVENT_NAME:-this event} on ${REF:-this ref}; a tag names a commit main already scanned."
    return 0
  fi
  # shellcheck disable=SC2086 # opts is one or two git log arguments
  n=$(git rev-list --count $opts)
  echo "Scanning $n commit(s): git log $opts"
  gitleaks git --no-banner --redact --verbose --exit-code 3 --log-opts="$opts" . || rc=$?
  case "$rc" in
    0) echo "No secrets in $n commit(s)." ;;
    3)
      echo "::error title=Secret committed::gitleaks found a secret in $opts (redacted above: commit, file, line, rule). Rotate it first - removing it from the branch does not un-publish it - then rewrite the commits that carry it."
      exit 3
      ;;
    *) die "Secret scan did not run" "gitleaks exited $rc. Nothing is known about these commits; this is not a clean result." ;;
  esac
}

case "${1-}" in
  install) install ;;
  range) range ;;
  scan) scan ;;
  *)
    echo "usage: $0 install | range | scan" >&2
    exit 2
    ;;
esac
