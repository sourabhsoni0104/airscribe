#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 "Usage: notarize-release.sh <AirScribe.app> <notarytool-keychain-profile>"
  exit 1
fi

APP_PATH=${1:A}
KEYCHAIN_PROFILE=$2
OUTPUT_DIR=${APP_PATH:h}
ZIP_PATH=${OUTPUT_DIR}/AirScribe.zip

ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
spctl --assess --type execute --verbose=2 "${APP_PATH}"
print "${ZIP_PATH}"
