#!/usr/bin/env bash
set -euo pipefail

TABLET_HOST="${TABLET_HOST:-10.11.99.1}"
APP_DIR="/home/root/xovi/exthome/appload/remarkable-lichess"
STAGING_DIR="${APP_DIR}.new"

if [ ! -d "dist/remarkable-lichess" ]; then
  echo "dist/remarkable-lichess not found -- run scripts/build-rm.sh first" >&2
  exit 1
fi

# Stage into a sibling dir and swap into place only once the transfer fully
# succeeds, rather than wiping APP_DIR up front -- that used to mean a scp
# that failed or got interrupted mid-transfer (a real risk over this device's
# own wifi/USB link) left the device with no app at all, since the old
# rm -rf ran unconditionally before the copy even started.
ssh "root@${TABLET_HOST}" "rm -rf '${STAGING_DIR}' && mkdir -p '${STAGING_DIR}'"
scp -r dist/remarkable-lichess/* "root@${TABLET_HOST}:${STAGING_DIR}/"
# The app layout changed once before (flat `backend` file -> `backend/entry`)
# and a stale flat file would collide with the new directory of the same name
# if we just copied over it -- still wipe APP_DIR here, but only now that the
# new contents are already fully staged and known-good.
ssh "root@${TABLET_HOST}" "rm -rf '${APP_DIR}' && mv '${STAGING_DIR}' '${APP_DIR}'"
echo "Deployed to ${TABLET_HOST}:${APP_DIR} — relaunch AppLoad on the tablet to pick it up."
