#!/usr/bin/env bash
# The pinned CLI tools CI uses, each an exact version checked against a
# sha256 before it runs. Used by .github/workflows/ci.yml and by the tests
# under tests/ when they are run locally, so CI and a laptop run the same
# binaries.
#
#   .github/scripts/tools.sh install <tool>...   kubeconform shellcheck tofu helm
#   .github/scripts/tools.sh dir                 print the bin directory
#
# Binaries land in $TOOLS_DIR (default: $RUNNER_TEMP/tools in CI,
# ~/.cache/oci-free-tools otherwise). In CI the directory is appended to
# $GITHUB_PATH, which reaches the steps AFTER the one that ran this.
#
# Why not the runner's own copies, or setup-* actions: ubuntu-latest ships a
# helm and a shellcheck whose versions move under us whenever the image is
# rebuilt, and a lint result should not change on a day nobody pushed. A
# downloaded binary checked against a recorded digest cannot.
#
# Digests come from each project's published checksum file (kubeconform
# CHECKSUMS, tofu SHA256SUMS, helm .sha256sum), except shellcheck, which
# publishes none: its digest was recorded at the pin (2026-11-04) and a
# mismatch means the release asset changed, which is worth failing on.
set -Eeuo pipefail

KUBECONFORM_VERSION=0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
SHELLCHECK_VERSION=0.11.0
SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
TOFU_VERSION=1.13.2
TOFU_SHA256=ac05d9952662c7db28dd57e93f0a68018837bfdf9342384ec0987977c16a9645
HELM_VERSION=4.2.4
HELM_SHA256=c306b46f719b0a4da32d0f78ee21bf90ce8d602f15b22ab753f0674d1670a7f3

if [ -n "${TOOLS_DIR:-}" ]; then
  :
elif [ -n "${RUNNER_TEMP:-}" ]; then
  TOOLS_DIR=$RUNNER_TEMP/tools
else
  TOOLS_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/oci-free-tools
fi
BIN=$TOOLS_DIR/bin

die() {
  echo "::error title=tools.sh::$*" >&2
  exit 2
}

# fetch <url> <sha256> <archive-name>: download into a fresh temp dir and
# verify. Prints the directory.
fetch() {
  local url=$1 sum=$2 name=$3 tmp
  tmp=$(mktemp -d "$TOOLS_DIR/dl.XXXXXX")
  curl -fsSLo "$tmp/$name" "$url" || die "download failed: $url"
  echo "$sum  $tmp/$name" | sha256sum -c --quiet - || die "checksum mismatch: $url"
  echo "$tmp"
}

# Installed already at this exact version? A marker per version, so bumping a
# pin in this file reinstalls rather than trusting a stale binary.
have() { [ -x "$BIN/$1" ] && [ -f "$BIN/.$1-$2" ]; }
mark() { rm -f "$BIN/.$1-"*; touch "$BIN/.$1-$2"; }

install_one() {
  local d
  case "$1" in
    kubeconform)
      have kubeconform "$KUBECONFORM_VERSION" && return 0
      d=$(fetch "https://github.com/yannh/kubeconform/releases/download/v$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" \
        "$KUBECONFORM_SHA256" k.tgz)
      tar -xzf "$d/k.tgz" -C "$BIN" kubeconform
      mark kubeconform "$KUBECONFORM_VERSION"
      ;;
    shellcheck)
      have shellcheck "$SHELLCHECK_VERSION" && return 0
      d=$(fetch "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.xz" \
        "$SHELLCHECK_SHA256" s.txz)
      tar -xJf "$d/s.txz" -C "$d"
      install -m 0755 "$d/shellcheck-v$SHELLCHECK_VERSION/shellcheck" "$BIN/shellcheck"
      mark shellcheck "$SHELLCHECK_VERSION"
      ;;
    tofu)
      have tofu "$TOFU_VERSION" && return 0
      d=$(fetch "https://github.com/opentofu/opentofu/releases/download/v$TOFU_VERSION/tofu_${TOFU_VERSION}_linux_amd64.tar.gz" \
        "$TOFU_SHA256" t.tgz)
      tar -xzf "$d/t.tgz" -C "$BIN" tofu
      mark tofu "$TOFU_VERSION"
      ;;
    helm)
      have helm "$HELM_VERSION" && return 0
      d=$(fetch "https://get.helm.sh/helm-v$HELM_VERSION-linux-amd64.tar.gz" "$HELM_SHA256" h.tgz)
      tar -xzf "$d/h.tgz" -C "$d"
      install -m 0755 "$d/linux-amd64/helm" "$BIN/helm"
      mark helm "$HELM_VERSION"
      ;;
    *) die "unknown tool '$1'" ;;
  esac
  rm -rf "$d"
}

case "${1-}" in
  install)
    shift
    [ "$#" -gt 0 ] || die "install what?"
    [ "$(uname -sm)" = "Linux x86_64" ] || die "pins are for linux x86_64 only"
    mkdir -p "$BIN"
    for t in "$@"; do install_one "$t"; done
    if [ -n "${GITHUB_PATH:-}" ]; then echo "$BIN" >>"$GITHUB_PATH"; fi
    for t in "$@"; do
      case "$t" in
        kubeconform) "$BIN/kubeconform" -v ;;
        shellcheck) "$BIN/shellcheck" --version | sed -n 2p ;;
        tofu) "$BIN/tofu" version | head -1 ;;
        helm) "$BIN/helm" version --short ;;
      esac
    done
    ;;
  dir) echo "$BIN" ;;
  *)
    echo "usage: $0 install <kubeconform|shellcheck|tofu|helm>... | dir" >&2
    exit 2
    ;;
esac
