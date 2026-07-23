#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${PROJECT_DIR}/dist/Point.app"
SUBMISSION_PATH="${PROJECT_DIR}/dist/Point-0.1.2-notary.zip"
ARCHIVE_PATH="${PROJECT_DIR}/dist/Point-0.1.2.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "${NOTARY_PROFILE}" ]]; then
    print -u2 "Set NOTARY_PROFILE to a notarytool keychain profile."
    exit 1
fi

cd "${PROJECT_DIR}"
CONFIGURATION=release RELEASE=1 "${SCRIPT_DIR}/build-app.sh"

rm -f "${SUBMISSION_PATH}" "${ARCHIVE_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${SUBMISSION_PATH}"
xcrun notarytool submit \
    "${SUBMISSION_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}"
rm -f "${SUBMISSION_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ARCHIVE_PATH}"

print "Notarized ${APP_PATH} and created ${ARCHIVE_PATH}"
