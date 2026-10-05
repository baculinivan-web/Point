#!/bin/zsh
set -euo pipefail

# Build ConverterTool v4.3.0 from AdguardTeam/SafariConverterLib first.
# Its public release binary omits the required PublicSuffixList resource bundle.
CONVERTER="${1:?Usage: update-adblock-filters.sh /absolute/path/to/ConverterTool}"
PROJECT_DIR="${0:A:h:h}"
FILTER_DIR="${PROJECT_DIR}/Sources/BrowserEngine/Resources/AdBlock"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

for FILTER in 1 2; do
    curl -fsSL "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/${FILTER}.txt" \
        -o "${WORK_DIR}/${FILTER}.txt"
done
curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/LICENSE \
    -o "${WORK_DIR}/LICENSE.txt"
cat "${WORK_DIR}/2.txt" "${WORK_DIR}/1.txt" > "${WORK_DIR}/combined.txt"
"${CONVERTER}" convert --safari-version 26.0 --advanced-blocking false \
    --input-path "${WORK_DIR}/combined.txt" \
    --safari-rules-json-path "${WORK_DIR}/rules.json"

cp "${WORK_DIR}/rules.json" "${FILTER_DIR}/rules.json"
cp "${WORK_DIR}/2.txt" "${FILTER_DIR}/base.txt"
cp "${WORK_DIR}/1.txt" "${FILTER_DIR}/russian.txt"
cp "${WORK_DIR}/LICENSE.txt" "${FILTER_DIR}/LICENSE.txt"
print "Updated bundled filters. Run swift test --filter AdBlockTests before committing."
