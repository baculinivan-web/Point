#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_DIR="${PROJECT_DIR}/dist/Point.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
APP_ICON="${PROJECT_DIR}/icon.icon"
APP_ICON_INFO="${PROJECT_DIR}/.build/BrowserAppIcon-Info.plist"
cd "${PROJECT_DIR}"
swift build -c "${CONFIGURATION}"

XCSTRINGSTOOL="$(xcode-select -p)/usr/bin/xcstringstool"
if [[ ! -x "${XCSTRINGSTOOL}" ]]; then
    print -u2 "xcstringstool is required to compile Localizable.xcstrings."
    exit 1
fi
"${XCSTRINGSTOOL}" compile \
    "Sources/BrowserCore/Resources/Localizable.xcstrings" \
    --output-directory ".build/${CONFIGURATION}/Browser_BrowserCore.bundle" \
    --format stringsAndStringsdict

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp ".build/${CONFIGURATION}/Browser" "${MACOS_DIR}/Browser"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp -R "Resources/en.lproj" "${RESOURCES_DIR}/"
cp -R "Resources/ru.lproj" "${RESOURCES_DIR}/"
rm -rf "${APP_DIR}/Browser_BrowserUI.bundle"
rm -rf "${RESOURCES_DIR}/Browser_BrowserUI.bundle"
cp -R ".build/${CONFIGURATION}/Browser_BrowserUI.bundle" "${RESOURCES_DIR}/"
rm -rf "${APP_DIR}/Browser_BrowserCore.bundle"
rm -rf "${RESOURCES_DIR}/Browser_BrowserCore.bundle"
cp -R ".build/${CONFIGURATION}/Browser_BrowserCore.bundle" "${RESOURCES_DIR}/"

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
    --sign -
    --entitlements "Resources/Browser.entitlements"
)
codesign "${codesign_arguments[@]}" "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

print "Built ${APP_DIR} (ad-hoc signed)"
