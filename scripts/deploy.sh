#!/usr/bin/env bash
set -euo pipefail

TABLET_HOST="${TABLET_HOST:-10.11.99.1}"
APP_DIR="/home/root/xovi/exthome/appload/remarkable-lichess"

ssh "root@${TABLET_HOST}" "mkdir -p '${APP_DIR}'"
scp -r dist/remarkable-lichess/* "root@${TABLET_HOST}:${APP_DIR}/"
echo "Deployed to ${TABLET_HOST}:${APP_DIR} — relaunch AppLoad on the tablet to pick it up."
