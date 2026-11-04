#!/usr/bin/env bash
# Prompts for a Gmail app password, checks it against Gmail, and stores it.
# Prompted rather than passed as an argument on purpose: an argument would end
# up in shell history and in the Claude transcript.
set -uo pipefail

# Next to this script, where .gitignore covers it. It used to be
# ~/projects/oci-free/.smtp-pw, a directory that does not exist since the repo
# moved under ~/projects/personal: the write failed, and without `set -e` the
# script still printed "Saved".
OUT="$(cd "$(dirname "$0")" && pwd)/.smtp-pw"
USER_ADDR=$(grep -E '^SMTP_USER=' "$HOME/projects/personal/portfolio_site/backend/.env" \
            | cut -d= -f2- | tr -d '"' | tr -d '[:space:]')
case "$USER_ADDR" in
  *@*) ;;
  *) printf 'No SMTP_USER in portfolio_site/backend/.env; nothing to check against.\n' >&2; exit 1 ;;
esac

printf 'Gmail account : %s\n' "$USER_ADDR"
printf 'App password  : '
stty -echo 2>/dev/null; IFS= read -r PW; stty echo 2>/dev/null; printf '\n'

# Google shows it as 4 groups of 4; spaces and stray quotes are normal on paste.
PW=$(printf '%s' "$PW" | tr -d '"'"'"'' | tr -d '[:space:]')

if [ "${#PW}" -ne 16 ]; then
  printf '\n  That is %d characters after removing spaces. A Google app password is 16.\n' "${#PW}"
  printf '  Nothing was saved. Create one at https://myaccount.google.com/apppasswords\n'
  exit 1
fi

printf '\n  Checking it against Gmail...\n'
# The password reaches python on fd 3, not argv: an argument is readable in
# the process list by anyone on the machine for as long as the login takes.
if ! python3 - "$USER_ADDR" 3<<<"$PW" <<'PY'
import os, smtplib, ssl, sys
user = sys.argv[1]
with os.fdopen(3) as f:
    pw = f.read().rstrip("\n")
try:
    s = smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=20, context=ssl.create_default_context())
    s.login(user, pw); s.quit()
    print("  Accepted by Gmail.")
except smtplib.SMTPAuthenticationError as e:
    print(f"  Gmail rejected it ({e.smtp_code}). Not saved.")
    sys.exit(1)
except Exception as e:
    print(f"  Could not reach Gmail ({type(e).__name__}). Not saved.")
    sys.exit(1)
PY
then
  exit 1
fi

umask 077
if ! printf '%s' "$PW" > "$OUT" || ! chmod 600 "$OUT"; then
  printf '  Could not write %s. Nothing was saved.\n' "$OUT" >&2
  exit 1
fi
printf '  Saved to %s\n' "${OUT/$HOME/\~}"
printf '\n  Now tell Claude: "new smtp password saved"\n'
