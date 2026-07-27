#!/usr/bin/env bash
set -euo pipefail

TABLET_HOST="${TABLET_HOST:-10.11.99.1}"
TABLET_IDENTITY_FILE="${TABLET_IDENTITY_FILE:-}"
APP_DIR="/home/root/xovi/exthome/appload/remarkable-lichess"
STAGING_DIR="${APP_DIR}.new"
BACKUP_DIR="/home/root/xovi/exthome/appload-backups/remarkable-lichess.previous"
SSH_ARGS=()
if [ -n "${TABLET_IDENTITY_FILE}" ]; then
  SSH_ARGS=(-i "${TABLET_IDENTITY_FILE}")
fi

if [ ! -d "dist/remarkable-lichess" ]; then
  echo "dist/remarkable-lichess not found -- run scripts/build-rm.sh first" >&2
  exit 1
fi

# Stage into a sibling dir and swap into place only once the transfer fully
# succeeds, rather than wiping APP_DIR up front -- that used to mean a scp
# that failed or got interrupted mid-transfer (a real risk over this device's
# own wifi/USB link) left the device with no app at all, since the old
# rm -rf ran unconditionally before the copy even started.
ssh "${SSH_ARGS[@]}" "root@${TABLET_HOST}" "rm -rf '${STAGING_DIR}' && mkdir -p '${STAGING_DIR}'"
scp "${SSH_ARGS[@]}" -r dist/remarkable-lichess/* "root@${TABLET_HOST}:${STAGING_DIR}/"
ssh "${SSH_ARGS[@]}" "root@${TABLET_HOST}" "
    set -e
    test -x '${STAGING_DIR}/backend/entry'
    test -s '${STAGING_DIR}/resources.rcc'
    mkdir -p '$(dirname "${BACKUP_DIR}")'
    rm -rf '${BACKUP_DIR}'
    if test -e '${APP_DIR}'; then mv '${APP_DIR}' '${BACKUP_DIR}'; fi
    if ! mv '${STAGING_DIR}' '${APP_DIR}'; then
        if test -e '${BACKUP_DIR}'; then mv '${BACKUP_DIR}' '${APP_DIR}'; fi
        exit 1
    fi
"
echo "Deployed to ${TABLET_HOST}:${APP_DIR} — relaunch AppLoad on the tablet to pick it up."
