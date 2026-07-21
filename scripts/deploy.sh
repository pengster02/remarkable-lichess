#!/usr/bin/env bash
set -euo pipefail

TABLET_HOST="${TABLET_HOST:-10.11.99.1}"
APP_DIR="/home/root/xovi/exthome/appload/remarkable-lichess"

# Wipe and recreate first: the app layout changed (flat `backend` file ->
# `backend/entry`), and a stale flat file would collide with the new directory
# of the same name if we just copied over it.
ssh "root@${TABLET_HOST}" "rm -rf '${APP_DIR}' && mkdir -p '${APP_DIR}'"
scp -r dist/remarkable-lichess/* "root@${TABLET_HOST}:${APP_DIR}/"
echo "Deployed to ${TABLET_HOST}:${APP_DIR} — relaunch AppLoad on the tablet to pick it up."
