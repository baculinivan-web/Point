#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CONFIGURATION="${CONFIGURATION:-debug}"
BUILD_ROOT="${SWIFT_SCRATCH_PATH:-${PROJECT_DIR}/.build}"
APP_DIR="${PROJECT_DIR}/dist/Point.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
APP_ICON="${PROJECT_DIR}/icon.icon"
APP_ICON_INFO="${BUILD_ROOT}/BrowserAppIcon-Info.plist"
cd "${PROJECT_DIR}"
swift build -c "${CONFIGURATION}" --scratch-path "${BUILD_ROOT}"

XCSTRINGSTOOL="$(xcode-select -p)/usr/bin/xcstringstool"
if [[ ! -x "${XCSTRINGSTOOL}" ]]; then
    print -u2 "xcstringstool is required to compile Localizable.xcstrings."
    exit 1
fi
"${XCSTRINGSTOOL}" compile \
    "Sources/BrowserCore/Resources/Localizable.xcstrings" \
    --output-directory "${BUILD_ROOT}/${CONFIGURATION}/Browser_BrowserCore.bundle" \
    --format stringsAndStringsdict

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${HELPERS_DIR}"
cp "${BUILD_ROOT}/${CONFIGURATION}/Browser" "${MACOS_DIR}/Browser"
cp "${BUILD_ROOT}/${CONFIGURATION}/point-browser-mcp" "${HELPERS_DIR}/point-browser-mcp"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp -R "Resources/en.lproj" "${RESOURCES_DIR}/"
cp -R "Resources/ru.lproj" "${RESOURCES_DIR}/"
rm -rf "${APP_DIR}/Browser_BrowserUI.bundle"
rm -rf "${RESOURCES_DIR}/Browser_BrowserUI.bundle"
cp -R "${BUILD_ROOT}/${CONFIGURATION}/Browser_BrowserUI.bundle" "${RESOURCES_DIR}/"
rm -rf "${APP_DIR}/Browser_BrowserCore.bundle"
rm -rf "${RESOURCES_DIR}/Browser_BrowserCore.bundle"
cp -R "${BUILD_ROOT}/${CONFIGURATION}/Browser_BrowserCore.bundle" "${RESOURCES_DIR}/"

xcrun actool \
    --compile "${RESOURCES_DIR}" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon icon \
    --output-partial-info-plist "${APP_ICON_INFO}" \
    --output-format human-readable-text \
    "${APP_ICON}"

SIGNING_IDENTITY="${POINT_SIGNING_IDENTITY:-}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2; exit}')"
fi
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2; exit}')"
fi
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_IDENTITY=-
    print -u2 "No signing identity available; ad-hoc builds may prompt for Keychain access after rebuilding."
fi
codesign_arguments=(
    --force
    --sign "${SIGNING_IDENTITY}"
    --entitlements "Resources/Browser.entitlements"
)
codesign --force --sign "${SIGNING_IDENTITY}" "${HELPERS_DIR}/point-browser-mcp"
codesign "${codesign_arguments[@]}" "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

print "Built ${APP_DIR} (signing identity: ${SIGNING_IDENTITY})"
