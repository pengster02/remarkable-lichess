#!/usr/bin/env bash
set -euo pipefail

# Save a Lichess PAT and (re)start the local AppLoad emulator.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="${TOKEN_FILE:-${ROOT}/.lichess-token}"

TOKEN="${1:-${LICHESS_TOKEN:-}}"
if [ -z "${TOKEN}" ]; then
  if [ -t 0 ]; then
    echo "Paste your Lichess personal access token (lip_...), then Enter:"
    read -r TOKEN
  else
    echo "Usage: $0 lip_your_token" >&2
    echo "Or:    LICHESS_TOKEN=lip_... $0" >&2
    echo "Create one at:" >&2
    echo "  https://lichess.org/account/oauth/token/create?description=remarkable-lichess&scopes[]=board:play&scopes[]=challenge:read&scopes[]=challenge:write&scopes[]=preference:read" >&2
    exit 1
  fi
fi

TOKEN="$(printf '%s' "${TOKEN}" | tr -d ' \t\r\n')"
case "${TOKEN}" in
  lip_*) ;;
  *)
    echo "Token should start with lip_" >&2
    exit 1
    ;;
esac

# Quick live check before wasting a rebuild cycle.
HTTP_CODE="$(curl -s -o /tmp/lichess-account.json -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  https://lichess.org/api/account || true)"
if [ "${HTTP_CODE}" != "200" ]; then
  echo "Lichess rejected that token (HTTP ${HTTP_CODE}):" >&2
  cat /tmp/lichess-account.json >&2 || true
  echo >&2
  exit 1
fi
USERNAME="$(python3 -c 'import json; print(json.load(open("/tmp/lichess-account.json")).get("username","?"))' 2>/dev/null || echo "?")"
echo "Token OK — signed in as ${USERNAME}"
printf '%s\n' "${TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"
echo "Saved to ${TOKEN_FILE}"

export LICHESS_TOKEN="${TOKEN}"
exec "${ROOT}/scripts/run-local.sh"
