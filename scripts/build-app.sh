#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_DIR="${PROJECT_DIR}/dist/Browser.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

cd "${PROJECT_DIR}"
swift build -c "${CONFIGURATION}"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp ".build/${CONFIGURATION}/Browser" "${MACOS_DIR}/Browser"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
rm -rf "${APP_DIR}/Browser_BrowserUI.bundle"
rm -rf "${RESOURCES_DIR}/Browser_BrowserUI.bundle"
cp -R ".build/${CONFIGURATION}/Browser_BrowserUI.bundle" "${RESOURCES_DIR}/"

codesign \
    --force \
    --sign - \
    --entitlements "Resources/Browser.entitlements" \
    "${APP_DIR}"

print "Built ${APP_DIR}"
