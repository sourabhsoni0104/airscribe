#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "Usage: generate-appcast.sh <directory-containing-signed-release-archives>"
  exit 1
fi

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
DERIVED_DATA=${AIRSCRIBE_DERIVED_DATA:-${TMPDIR%/}/AirScribeReleaseDerivedData}
DOWNLOAD_PREFIX=${AIRSCRIBE_DOWNLOAD_URL_PREFIX:-}

if [[ -z ${DOWNLOAD_PREFIX} ]]; then
  print -u2 "Set AIRSCRIBE_DOWNLOAD_URL_PREFIX to the versioned HTTPS release directory."
  print -u2 "Example: https://github.com/OWNER/REPO/releases/download/v1.0.0/"
  exit 1
fi
if [[ ${DOWNLOAD_PREFIX} != https://* ]]; then
  print -u2 "AIRSCRIBE_DOWNLOAD_URL_PREFIX must use HTTPS."
  exit 1
fi

SPARKLE_TOOL=$(find "${DERIVED_DATA}/SourcePackages/artifacts" -type f -path '*/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null || true)

if [[ -z ${SPARKLE_TOOL} ]]; then
  xcodebuild \
    -project "${APP_DIR}/AirScribe.xcodeproj" \
    -derivedDataPath "${DERIVED_DATA}" \
    -resolvePackageDependencies
  SPARKLE_TOOL=$(find "${DERIVED_DATA}/SourcePackages/artifacts" -type f -path '*/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null || true)
fi
if [[ -z ${SPARKLE_TOOL} ]]; then
  print -u2 "The updater publishing tool was not found. Resolve Swift packages first."
  exit 1
fi

"${SPARKLE_TOOL}" --download-url-prefix "${DOWNLOAD_PREFIX}" "${1:A}"
