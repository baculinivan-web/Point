#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${PROJECT_DIR}/dist/Point.app"
DMG_PATH="${PROJECT_DIR}/dist/Point.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/point-release.XXXXXX")"

cleanup() {
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

cd "${PROJECT_DIR}"
CONFIGURATION=release "${SCRIPT_DIR}/build-app.sh"
rm -f "${DMG_PATH}"
ditto "${APP_PATH}" "${STAGING_DIR}/Point.app"
hdiutil create \
    -volname "Point" \
    -srcfolder "${STAGING_DIR}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

print "Created ${DMG_PATH}"
