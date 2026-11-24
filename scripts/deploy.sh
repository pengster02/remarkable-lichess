#!/usr/bin/env bash
set -euo pipefail

TABLET_HOST="${TABLET_HOST:-10.11.99.1}"
TABLET_IDENTITY_FILE="${TABLET_IDENTITY_FILE:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${ROOT}/dist/remarkable-lichess"
APPS_ROOT="/home/root/xovi/exthome/appload"
APP_DIR="${APPS_ROOT}/remarkable-lichess"
BACKUP_ROOT="/home/root/xovi/exthome/appload-backups"
BACKUP_DIR="${BACKUP_ROOT}/remarkable-lichess.previous"
LOCK_DIR="${BACKUP_ROOT}/remarkable-lichess.lock"
STAGING_PREFIX="${BACKUP_ROOT}/remarkable-lichess.stage."
SSH_ARGS=()
if [ -n "${TABLET_IDENTITY_FILE}" ]; then
  SSH_ARGS=(-i "${TABLET_IDENTITY_FILE}")
fi

if [ ! -x "${DIST}/backend/entry" ] || [ ! -s "${DIST}/manifest.json" ] || [ ! -s "${DIST}/resources.rcc" ]; then
  echo "The app bundle is incomplete. Run scripts/build-rm.sh first." >&2
  exit 1
fi

remote() {
  # The conditional expansion also supports macOS Bash 3 with nounset enabled.
  # shellcheck disable=SC2029
  ssh ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} "root@${TABLET_HOST}" "$@"
}

# Stage each copy outside the scan root. A live sibling exposes duplicate app
# IDs, and a fixed staging directory lets concurrent copies overwrite each other.
STAGING_DIR="$(remote "
    set -eu
    mkdir -p '${BACKUP_ROOT}'
    stage=\$(mktemp -d '${STAGING_PREFIX}XXXXXX')
    mkdir \"\$stage/payload\"
    printf '%s\\n' \"\$stage\"
")"
stage_suffix="${STAGING_DIR#"${STAGING_PREFIX}"}"
if [[ "$stage_suffix" == "$STAGING_DIR" || ${#stage_suffix} -ne 6 || "$stage_suffix" == *[![:alnum:]]* ]]; then
  echo "The tablet returned an invalid staging directory." >&2
  exit 1
fi

cleanup_staging() {
  remote "if test ! -e '${STAGING_DIR}/previous'; then rm -rf '${STAGING_DIR}'; fi" >/dev/null 2>&1 || true
}
trap cleanup_staging EXIT
scp ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} -r "${DIST}/"* "root@${TABLET_HOST}:${STAGING_DIR}/payload/"

if remote "
    set -eu
    test -x '${STAGING_DIR}/payload/backend/entry'
    test -s '${STAGING_DIR}/payload/manifest.json'
    test -s '${STAGING_DIR}/payload/resources.rcc'
    chmod 0755 '${STAGING_DIR}/payload'
    mkdir -p '${APPS_ROOT}'
    if ! mkdir '${LOCK_DIR}'; then
        echo 'Another reMarkable Lichess installation holds the deployment lock.' >&2
        exit 1
    fi
    finish() {
        if test -e '${STAGING_DIR}/previous' && test ! -e '${APP_DIR}'; then
            mv '${STAGING_DIR}/previous' '${APP_DIR}' ||
                echo 'Restore the previous app from ${STAGING_DIR}/previous.' >&2
        fi
        rmdir '${LOCK_DIR}' || true
    }
    trap finish 0
    trap 'exit 1' HUP INT TERM
    if test -e '${APP_DIR}'; then mv '${APP_DIR}' '${STAGING_DIR}/previous'; fi
    mv '${STAGING_DIR}/payload' '${APP_DIR}'
    if test -e '${STAGING_DIR}/previous'; then
        rm -rf '${BACKUP_DIR}'
        mv '${STAGING_DIR}/previous' '${BACKUP_DIR}'
    fi
    rmdir '${STAGING_DIR}'
"; then
  trap - EXIT
else
  status=$?
  # An SSH disconnect leaves the remote swap uncertain. Cleanup could race it.
  if [ "$status" -eq 255 ]; then
    trap - EXIT
    echo "Connection lost during install. Check ${STAGING_DIR} on the tablet before retrying." >&2
  fi
  exit "$status"
fi

echo "Deployed to ${TABLET_HOST}:${APP_DIR} — relaunch AppLoad on the tablet to pick it up."
