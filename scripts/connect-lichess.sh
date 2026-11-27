#!/usr/bin/env bash
set -euo pipefail

# Save a Lichess PAT and (re)start the local AppLoad emulator.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="${TOKEN_FILE:-${ROOT}/.lichess-token}"

TOKEN="${1:-${LICHESS_TOKEN:-}}"
if [ -z "${TOKEN}" ]; then
  if [ -t 0 ]; then
    echo "Paste your Lichess personal access token, then Enter:"
    read -r -s TOKEN
    printf '\n'
  else
    echo "Usage: $0 YOUR_TOKEN" >&2
    echo "Or:    LICHESS_TOKEN=YOUR_TOKEN $0" >&2
    echo "Create one at:" >&2
    echo "  https://lichess.org/account/oauth/token/create?description=remarkable-lichess&scopes[]=board:play&scopes[]=challenge:read&scopes[]=challenge:write&scopes[]=preference:read" >&2
    exit 1
  fi
fi

TOKEN="$(printf '%s' "${TOKEN}" | tr -d ' \t\r\n')"
# Lichess guarantees ASCII syntax. A fixed prefix can change, and deferring validation sends malformed input.
if ! (export LC_ALL=C; [[ "${TOKEN}" =~ ^[A-Za-z0-9_]+$ ]]); then
  echo "A Lichess token must contain only letters A-Z, digits, and underscores." >&2
  exit 1
fi

# Quick live check before wasting a rebuild cycle.
ACCOUNT_RESPONSE="$(mktemp)"
trap 'rm -f "$ACCOUNT_RESPONSE"' EXIT
# curl can print 200 on a failed body transfer. Checking only the status
# accepts partial responses, while --fail mixes HTTP and transfer failures.
if ! HTTP_CODE="$(printf 'Authorization: Bearer %s\n' "${TOKEN}" | \
  curl -sS --connect-timeout 5 --max-time 15 -o "$ACCOUNT_RESPONSE" -w '%{http_code}' \
    -A remarkable-lichess -H @- https://lichess.org/api/account)"; then
  echo "Could not complete the Lichess account transfer. Check your connection and try again." >&2
  exit 1
fi
case "${HTTP_CODE}" in
  200) ;;
  401|403)
    echo "Lichess rejected that token (HTTP ${HTTP_CODE})." >&2
    exit 1
    ;;
  *)
    echo "Lichess could not verify the token (HTTP ${HTTP_CODE})." >&2
    exit 1
    ;;
esac
if ! USERNAME="$(python3 -c '
import json, sys
account = json.load(sys.stdin)
if not all(isinstance(account.get(key), str) and account[key].strip() for key in ("id", "username")):
    sys.exit(1)
print(account["username"])
' < "$ACCOUNT_RESPONSE" 2>/dev/null)"; then
  echo "Lichess returned an invalid account profile. Try again." >&2
  exit 1
fi

# Send the token on stdin and disable curl configuration for this POST so
# redirects cannot forward the body and local trace settings cannot print it.
unset scope_response
if ! scope_response="$(printf '%s' "${TOKEN}" | \
  curl -q -fsS --connect-timeout 5 --max-time 15 -A remarkable-lichess \
    -H 'Content-Type: text/plain' --data-binary @- https://lichess.org/api/token/test)"; then
  echo "Could not verify Lichess token permissions. Check your connection and try again." >&2
  exit 1
fi
if printf '%s\n%s\n' "${TOKEN}" "${scope_response}" | python3 -c '
import json, sys
token = sys.stdin.readline().rstrip("\n")
grant = json.load(sys.stdin)[token]
if grant is None:
    sys.exit(2)
with open(sys.argv[1]) as profile:
    if grant["userId"] != json.load(profile)["id"]:
        sys.exit(1)
if "board:play" not in [scope.strip() for scope in grant["scopes"].split(",")]:
    sys.exit(3)
' "$ACCOUNT_RESPONSE" 2>/dev/null; then
  unset scope_response
else
  case "$?" in
    2) echo "Lichess rejected this token." >&2 ;;
    3) echo "Create a Lichess token with Board play (board:play) permission." >&2 ;;
    *) echo "Lichess returned invalid token permissions. Try again." >&2 ;;
  esac
  exit 1
fi
echo "Token OK — signed in as ${USERNAME}"
if [ -f "${TOKEN_FILE}" ]; then chmod 600 "${TOKEN_FILE}"; fi
(umask 077; printf '%s\n' "${TOKEN}" > "${TOKEN_FILE}")
chmod 600 "${TOKEN_FILE}"
echo "Saved to ${TOKEN_FILE}"

rm -f "$ACCOUNT_RESPONSE"
trap - EXIT
export LICHESS_TOKEN="${TOKEN}"
exec "${ROOT}/scripts/run-local.sh"
