#!/usr/bin/env bash
# Prompts for a Gmail app password, checks it against Gmail, and stores it.
# Prompted rather than passed as an argument on purpose: an argument would end
# up in shell history and in the Claude transcript.
set -uo pipefail

OUT="$HOME/projects/oci-free/.smtp-pw"
USER_ADDR=$(grep -E '^SMTP_USER=' "$HOME/projects/personal/portfolio_site/backend/.env" \
            | cut -d= -f2- | tr -d '"' | tr -d '[:space:]')

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
if ! python3 - "$USER_ADDR" "$PW" <<'PY'
import smtplib, ssl, sys
user, pw = sys.argv[1], sys.argv[2]
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
printf '%s' "$PW" > "$OUT"
chmod 600 "$OUT"
printf '  Saved to %s\n' "${OUT/$HOME/\~}"
printf '\n  Now tell Claude: "new smtp password saved"\n'
