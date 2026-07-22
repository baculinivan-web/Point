#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_DIR="${PROJECT_DIR}/dist/Browser.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

cd "${PROJECT_DIR}"
swift build -c "${CONFIGURATION}"

mkdir -p "${MACOS_DIR}"
cp ".build/${CONFIGURATION}/Browser" "${MACOS_DIR}/Browser"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

codesign \
    --force \
    --sign - \
    --entitlements "Resources/Browser.entitlements" \
    "${APP_DIR}"

print "Built ${APP_DIR}"
