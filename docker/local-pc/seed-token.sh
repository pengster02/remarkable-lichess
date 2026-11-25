#!/usr/bin/env bash
set -euo pipefail

config="$1"
mode="$2"
if ! IFS= read -r token || [ -z "$token" ] || IFS= read -r extra || [ -n "${extra:-}" ]; then
  echo "Expected one complete emulator token on standard input." >&2
  exit 1
fi

# Sign-out removes the token. Testing for the token or adding a separate marker
# would lose the initialization state of an existing or migrated directory.
if [ "$mode" = initial ] && [ -d "$config" ]; then
  exit 0
fi

umask 077
stage="$(mktemp -d "${config%/*}/.seed-token.XXXXXXXX")"
trap 'if [ -d "$stage" ]; then rm -r -- "$stage"; fi' EXIT
printf '%s\n' "$token" > "$stage/token"

if [ ! -d "$config" ] &&
  mv -Tn -- "$stage" "$config" 2>/dev/null && [ ! -d "$stage" ]; then
  exit 0
fi
if [ ! -d "$config" ]; then
  echo "Could not initialize the emulator configuration directory." >&2
  exit 1
fi
if [ "$mode" = replace ]; then
  mv -fT -- "$stage/token" "$config/token"
fi
