#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR=${AIRSCRIBE_OUTPUT_DIR:-${APP_DIR}/build/release}
ARCHIVE_PATH=${OUTPUT_DIR}/AirScribe.xcarchive
EXPORT_PATH=${OUTPUT_DIR}/export
SIGNING_IDENTITY=${AIRSCRIBE_CODE_SIGN_IDENTITY:-Developer ID Application}

if [[ -z ${DEVELOPMENT_TEAM:-} ]]; then
  print -u2 "DEVELOPMENT_TEAM is required for a Developer ID release."
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
cd "${APP_DIR}"
xcodegen generate
xcodebuild \
  -project AirScribe.xcodeproj \
  -scheme AirScribe \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
  ARCHS=arm64 \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  archive
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist Config/ExportOptions.plist

codesign --verify --deep --strict --verbose=2 "${EXPORT_PATH}/AirScribe.app"
print "${EXPORT_PATH}/AirScribe.app"
