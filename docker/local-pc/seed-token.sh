#!/usr/bin/env bash
set -euo pipefail

config="$1"
mode="$2"
transaction="${3:-}"
if [ -n "$transaction" ] && ! [[ "$transaction" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid emulator token transaction." >&2
  exit 1
fi
stage="${config%/*}/.seed-token.${transaction}"

if [ "$mode" = commit ] || [ "$mode" = rollback ]; then
  [ -n "$transaction" ] || exit 1
  [ -d "$stage" ] || exit 0
  # Compare inodes so rollback leaves any newer sign-in or sign-out intact.
  if [ "$mode" = rollback ] && [ "$stage/applied" -ef "$config/token" ]; then
    if [ -e "$stage/previous" ] || [ -L "$stage/previous" ]; then
      mv -fT -- "$stage/previous" "$config/token"
    else
      rm -- "$config/token"
      if [ -f "$stage/created-config" ]; then
        rmdir --ignore-fail-on-non-empty -- "$config"
      fi
    fi
  fi
  rm -r -- "$stage"
  exit 0
fi

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
if [ -n "$transaction" ]; then
  mkdir -- "$stage"
else
  stage="$(mktemp -d "${config%/*}/.seed-token.XXXXXXXX")"
fi
trap 'if [ -z "$transaction" ] || [ ! -e "$stage/applied" ]; then rm -r -- "$stage"; fi' EXIT
printf '%s\n' "$token" > "$stage/token"

if [ -n "$transaction" ]; then
  ln -- "$stage/token" "$stage/applied"
fi
if [ ! -d "$config" ]; then
  mkdir -- "$stage/config"
  mv -T -- "$stage/token" "$stage/config/token"
  if [ -n "$transaction" ]; then
    touch "$stage/created-config"
  fi
  if mv -Tn -- "$stage/config" "$config" 2>/dev/null && [ ! -d "$stage/config" ]; then
    exit 0
  fi
  rm -f -- "$stage/created-config"
  mv -T -- "$stage/config/token" "$stage/token"
fi
if [ ! -d "$config" ]; then
  echo "Could not initialize the emulator configuration directory." >&2
  exit 1
fi
if [ "$mode" = replace ]; then
  if [ -n "$transaction" ] && { [ -e "$config/token" ] || [ -L "$config/token" ]; }; then
    # A private link keeps the original inode. Moving it creates a gap, and a host copy exports it.
    ln -P -- "$config/token" "$stage/previous"
  fi
  mv -fT -- "$stage/token" "$config/token"
fi
