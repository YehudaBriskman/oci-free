#!/usr/bin/env bash
#
# Build and roll out the portfolio images.
#
# The images are built on the ARM node itself and imported straight into k3s's
# containerd: there is no registry in this setup, which is why the deployments
# pin imagePullPolicy: Never. Building here and pushing is not an option — the
# node is arm64 and the laptop is not.
#
#   ./deploy-portfolio.sh [web|api|both]
set -euo pipefail

NODE="${NODE:-ubuntu@100.79.242.82}"
SRC="${SRC:-$HOME/projects/personal/portfolio_site}"
REMOTE_DIR="portfolio"
TARGET="${1:-both}"

say() { printf '\n==> %s\n' "$*"; }

sync_source() {
  local component="$1"
  say "Syncing ${component}"
  rsync -az --delete \
    --exclude node_modules --exclude dist --exclude .git \
    --exclude '*.log' --exclude .env \
    "${SRC}/${component}/" "${NODE}:${REMOTE_DIR}/${component}/"
}

build_and_import() {
  local name="$1" dir="$2"
  say "Building ${name} on the node"
  ssh "$NODE" "cd ~/${REMOTE_DIR}/${dir} && docker build -t ${name}:latest ."
  say "Importing ${name} into k3s containerd"
  # Streamed through a pipe so the tarball never lands on the node's disk: the
  # boot volume is the free tier's allowance and images add up quickly.
  ssh "$NODE" "docker save ${name}:latest | sudo k3s ctr images import -"
}

case "$TARGET" in
  api)
    sync_source backend
    build_and_import portfolio-api backend
    kubectl -n prod rollout restart deploy/api
    kubectl -n prod rollout status deploy/api --timeout=180s
    ;;
  web)
    sync_source glassglow-folio-space
    build_and_import portfolio-web glassglow-folio-space
    kubectl -n prod rollout restart deploy/web
    kubectl -n prod rollout status deploy/web --timeout=180s
    ;;
  both)
    sync_source backend
    sync_source glassglow-folio-space
    build_and_import portfolio-api backend
    build_and_import portfolio-web glassglow-folio-space
    # web first, then api. The api renders pages by fetching the built shell
    # from web; restarting them together let it cache the outgoing pod's HTML
    # and serve asset URLs that had just stopped existing.
    kubectl -n prod rollout restart deploy/web
    kubectl -n prod rollout status deploy/web --timeout=180s
    kubectl -n prod rollout restart deploy/api
    kubectl -n prod rollout status deploy/api --timeout=180s
    ;;
  *)
    echo "usage: $0 [web|api|both]" >&2
    exit 2
    ;;
esac

say "Done"
