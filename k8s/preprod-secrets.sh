#!/usr/bin/env bash
#
# The three secrets preprod needs, created from nothing an operator has to
# invent twice.
#
#   kubectl apply -f k8s/portfolio-preprod.yaml
#   GITHUB_TOKEN=ghp_... ./k8s/preprod-secrets.sh
#
# GITHUB_TOKEN is the one value this script cannot invent, and it is optional:
# without it everything comes up and the contribution city draws its empty
# state. Mint it at github.com/settings/tokens with `read:user` and nothing
# else. To add it to a namespace that already has the secret, without
# rotating the fifteen generated keys beside it:
#
#   kubectl -n preprod patch secret portfolio-api-env --type merge \
#     -p "{\"stringData\":{\"GITHUB_TOKEN\":\"$GITHUB_TOKEN\"}}"
#   kubectl -n preprod rollout restart deploy/api
#
# The restart is not optional: an envFrom change is invisible to a running
# pod. The same two lines with `-n prod` do production, which needs this key
# just as much and has never had it either.
#
# What it creates, and why each one is here rather than copied from prod:
#
#   preprod-couch       COUCHDB_USER / COUCHDB_PASSWORD. Generated here, read
#                       by both the CouchDB container and the API, so the two
#                       cannot drift. Nothing outside this namespace knows it.
#
#   portfolio-api-env   The other sixteen keys the API's Zod schema wants.
#                       Deliberately NOT `kubectl get secret -n prod -o yaml |
#                       sed s/prod/preprod/`: that secret holds a Gmail app
#                       password and a CONTACT_TO that is a real mailbox, and
#                       copying it is how a test submission on an unreleased
#                       build ends up in the owner's inbox -- or how a bug in
#                       unreleased code ends up writing to the production
#                       content store. Preprod's SMTP points at the in-namespace
#                       sink and its CONTACT_TO is in `.invalid`, which RFC 2606
#                       guarantees can never resolve. There is no real
#                       credential in this file because preprod needs none.
#
#   ghcr-pull           Copied from prod, and this one is correct to copy: it
#                       is a read-only `read:packages` token for the registry
#                       both namespaces pull the same images from. Minting a
#                       second one would be a second thing to rotate for no
#                       gain in isolation.
#
# Re-running it is safe and does not rotate anything: existing secrets are left
# alone unless --rotate is passed. A rotation restarts the API and CouchDB,
# because an envFrom change is invisible to a running pod.
set -euo pipefail

NS=preprod
ROTATE=${1:-}

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need kubectl
need openssl

kubectl get ns "$NS" >/dev/null 2>&1 || {
  echo "no $NS namespace — apply k8s/portfolio-preprod.yaml first" >&2
  exit 1
}

have() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }
skip() { echo "  $1 exists, left alone (pass --rotate to replace)"; }

# ---------------------------------------------------------------- couch ------
if have preprod-couch && [ "$ROTATE" != "--rotate" ]; then
  skip preprod-couch
else
  # Base64 of 24 random bytes. CouchDB takes the password verbatim, so the only
  # requirement is that it survives being an environment variable and a YAML
  # scalar; `rand -base64` can emit `+` and `/`, both of which do, and neither
  # of which reaches a URL — the API sends it as an HTTP Basic header.
  COUCH_PW=$(openssl rand -base64 24)
  kubectl -n "$NS" create secret generic preprod-couch \
    --from-literal=COUCHDB_USER=portfolio_api \
    --from-literal=COUCHDB_PASSWORD="$COUCH_PW" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  preprod-couch written"
fi

# ---------------------------------------------------------------- api env ----
if have portfolio-api-env && [ "$ROTATE" != "--rotate" ]; then
  skip portfolio-api-env
else
  # The admin gate fails closed on an empty secret, so preprod gets its own
  # rather than prod's: the admin surface on an unreleased build should not be
  # openable with the production secret, and vice versa.
  ADMIN_SECRET=$(openssl rand -hex 32)
  #
  # Sixteen keys, and the four that are not obvious:
  #
  #   SMTP_*        the sink's Service name and port. Mailpit accepts any
  #                 login, so SMTP_USER and SMTP_PASS are names rather than
  #                 credentials -- but the API's schema refuses to start
  #                 without them, so they cannot simply be left out.
  #   MAIL_FROM,
  #   CONTACT_TO    both in `.invalid`, which RFC 2606 reserves and no
  #                 resolver will ever answer for. Belt and braces: if the
  #                 sink were removed and SMTP pointed at something real, the
  #                 mail still has nowhere to go.
  #   COUCHDB_URL   preprod's own store by Service name. COUCHDB_USER and
  #                 COUCHDB_PASSWORD are deliberately *not* here; they live in
  #                 preprod-couch, which the CouchDB pod reads too.
  #   SITE_URL      every absolute URL the API emits -- canonical links, OG
  #                 images, sitemap entries -- is built from this. Left at its
  #                 default it is https://yehudabriskman.com, so preprod would
  #                 serve pages claiming to be production and the one thing a
  #                 preview is for, seeing what a page says about itself,
  #                 would be the thing it got wrong.
  #   GITHUB_TOKEN  read from the operator's environment, because it is the
  #                 one value here nothing can generate. The contribution
  #                 city asks GitHub's GraphQL API for a year of
  #                 `contributionsCollection`, and that endpoint has no
  #                 anonymous mode at all -- unlike the REST calls in
  #                 github.ts, which is why this is the first key that cannot
  #                 be defaulted. Empty is a supported state and not a
  #                 failure: the service returns a year with no days and an
  #                 `error` string, the page draws its empty state, and
  #                 `[contributions] GITHUB_TOKEN is not set` goes to the pod
  #                 log. Scope needed is `read:user` and nothing else -- the
  #                 year of public contributions is all it reads, so a token
  #                 with repo write on it is strictly worse here.
  #   GITHUB_LOGIN  whose year the city draws. Separate from
  #                 ADMIN_GITHUB_LOGIN on purpose: one is an identity that
  #                 may administer the site, the other is a public profile
  #                 being read. They are the same person today and there is
  #                 no reason the schema should assume it.
  #
  # `--from-literal` rather than `--from-env-file`: the env-file form does not
  # strip quotes the way dotenv does, and the prod secret was once created with
  # `CONTACT_TO="a@b.com"` quotes and all, which failed the email validator at
  # boot. There is nothing to quote here.
  kubectl -n "$NS" create secret generic portfolio-api-env \
    --from-literal=NODE_ENV=production \
    --from-literal=PORT=5000 \
    --from-literal=EMAIL_PROVIDER=smtp \
    --from-literal=SMTP_HOST=mail \
    --from-literal=SMTP_PORT=1025 \
    --from-literal=SMTP_SECURE=false \
    --from-literal=SMTP_USER=preprod \
    --from-literal=SMTP_PASS=preprod \
    --from-literal=MAIL_FROM=noreply@preprod.invalid \
    --from-literal=MAIL_REPLY_TO= \
    --from-literal=CONTACT_TO=contact@preprod.invalid \
    --from-literal=COUCHDB_URL=http://couch:5984 \
    --from-literal=ADMIN_PROXY_SECRET="$ADMIN_SECRET" \
    --from-literal=ADMIN_GITHUB_LOGIN=YehudaBriskman \
    --from-literal=SITE_URL=https://preprod.yehudabriskman.com \
    --from-literal=WEB_ORIGIN=http://web \
    --from-literal=GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    --from-literal=GITHUB_LOGIN=YehudaBriskman \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  portfolio-api-env written"
  [ -n "${GITHUB_TOKEN:-}" ] || cat >&2 <<'NOTOKEN'
  NOTE: GITHUB_TOKEN was empty, so the contribution city will render its
        empty state. That is a correct, deliberate fallback and not a crash --
        see the head of this file for how to fill it in.
NOTOKEN
fi

# ---------------------------------------------------------------- ghcr -------
if have ghcr-pull && [ "$ROTATE" != "--rotate" ]; then
  skip ghcr-pull
else
  # Re-created rather than piped through `sed`: a secret fetched with `get -o
  # yaml` carries a resourceVersion, a uid and a creationTimestamp from the
  # object it came from, and re-applying those into another namespace is a
  # conflict waiting for a second run. Only the one payload key is carried.
  umask 077
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT
  if ! kubectl -n prod get secret ghcr-pull \
        -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$TMP" \
     || [ ! -s "$TMP" ]; then
    echo "  no ghcr-pull in prod to copy. Create it in both namespaces:" >&2
    echo "    kubectl -n preprod create secret docker-registry ghcr-pull \\" >&2
    echo "      --docker-server=ghcr.io --docker-username=<github-user> \\" >&2
    echo "      --docker-password=<PAT with read:packages>" >&2
    exit 1
  fi
  kubectl -n "$NS" create secret generic ghcr-pull \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$TMP" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  ghcr-pull copied from prod"
fi

# An envFrom change does not reach a running container, and the API caches its
# nodemailer transport and its CouchDB auth header at first use. Without this,
# a rotation appears to work and the next request still uses the old password.
if [ "$ROTATE" = "--rotate" ]; then
  kubectl -n "$NS" rollout restart deploy/couch deploy/api
  kubectl -n "$NS" rollout status deploy/couch --timeout=180s
  kubectl -n "$NS" rollout status deploy/api --timeout=180s
fi

echo
echo "preprod secrets in place. Content store is empty until it is seeded —"
echo "see 'Seeding preprod' in the README."
