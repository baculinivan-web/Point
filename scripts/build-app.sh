#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CONFIGURATION="${CONFIGURATION:-debug}"
RELEASE="${RELEASE:-0}"
APP_DIR="${PROJECT_DIR}/dist/Point.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
APP_ICON="${PROJECT_DIR}/icon.icon"
APP_ICON_INFO="${PROJECT_DIR}/.build/BrowserAppIcon-Info.plist"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

if [[ -z "${CODESIGN_IDENTITY}" && "${RELEASE}" == "1" ]]; then
    CODESIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk '/"Developer ID Application:/{ print $2; exit }'
    )"
fi
if [[ -z "${CODESIGN_IDENTITY}" && "${RELEASE}" != "1" ]]; then
    CODESIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk '/"Apple Development:|"Developer ID Application:/{ print $2; exit }'
    )"
fi
if [[ "${RELEASE}" == "1" && -z "${CODESIGN_IDENTITY}" ]]; then
    print -u2 "RELEASE=1 requires a Developer ID Application identity."
    exit 1
fi
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "${PROJECT_DIR}"
swift build -c "${CONFIGURATION}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp ".build/${CONFIGURATION}/Browser" "${MACOS_DIR}/Browser"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
rm -rf "${APP_DIR}/Browser_BrowserUI.bundle"
rm -rf "${RESOURCES_DIR}/Browser_BrowserUI.bundle"
cp -R ".build/${CONFIGURATION}/Browser_BrowserUI.bundle" "${RESOURCES_DIR}/"

xcrun actool \
    --compile "${RESOURCES_DIR}" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon icon \
    --output-partial-info-plist "${APP_ICON_INFO}" \
    --output-format human-readable-text \
    "${APP_ICON}"

codesign_arguments=(
    --force
    --sign "${CODESIGN_IDENTITY}"
    --entitlements "Resources/Browser.entitlements"
)
if [[ "${RELEASE}" == "1" ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi
codesign "${codesign_arguments[@]}" "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

print "Built ${APP_DIR} (signed with ${CODESIGN_IDENTITY})"
