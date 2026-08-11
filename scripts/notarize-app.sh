#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
print -u2 "notarize-app.sh is retained as a compatibility entry point; trusted beta releases use an unsigned DMG."
exec "${SCRIPT_DIR}/package-release.sh"
