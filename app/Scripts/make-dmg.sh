#!/bin/zsh
set -euo pipefail

# Builds the drag-to-install disk image users expect: a window showing
# AirScribe.app beside an Applications folder alias.
#
# Run this after notarize-release.sh has stapled the app. Apple recommends
# notarizing the disk image as well, so pass a notarytool keychain profile to
# have the image submitted and stapled too.
#
# Usage: make-dmg.sh <AirScribe.app> [notarytool-keychain-profile]

if (( $# < 1 || $# > 2 )); then
  print -u2 "Usage: make-dmg.sh <AirScribe.app> [notarytool-keychain-profile]"
  exit 1
fi

APP_PATH=${1:A}
KEYCHAIN_PROFILE=${2:-}
SIGNING_IDENTITY=${AIRSCRIBE_CODE_SIGN_IDENTITY:-Developer ID Application}
VOLUME_NAME=${AIRSCRIBE_DMG_VOLUME_NAME:-AirScribe}

if [[ ! -d ${APP_PATH} ]]; then
  print -u2 "No app bundle at ${APP_PATH}."
  exit 1
fi
if [[ ${APP_PATH:t} != AirScribe.app ]]; then
  print -u2 "Expected a bundle named AirScribe.app, got ${APP_PATH:t}."
  exit 1
fi

OUTPUT_DIR=${APP_PATH:h}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${APP_PATH}/Contents/Info.plist" 2>/dev/null || print "0.0.0")
DMG_PATH=${OUTPUT_DIR}/AirScribe-${VERSION}.dmg
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/AirScribeDMG.XXXXXX")
READWRITE_DMG=${STAGING_DIR}/rw.dmg
MOUNT_POINT=${STAGING_DIR}/mnt

cleanup() {
  if [[ -d ${MOUNT_POINT} ]]; then
    hdiutil detach "${MOUNT_POINT}" -quiet 2>/dev/null || true
  fi
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

# Stage exactly what the window should contain.
CONTENTS_DIR=${STAGING_DIR}/contents
mkdir -p "${CONTENTS_DIR}"
ditto "${APP_PATH}" "${CONTENTS_DIR}/AirScribe.app"
ln -s /Applications "${CONTENTS_DIR}/Applications"

# Give the mounted volume the app's own icon instead of a blank disk. Finder
# reads .VolumeIcon.icns from the volume root, but only when the volume carries
# the custom-icon flag, which is set after mounting below.
APP_ICON=${APP_PATH}/Contents/Resources/AppIcon.icns
if [[ -f ${APP_ICON} ]]; then
  ditto "${APP_ICON}" "${CONTENTS_DIR}/.VolumeIcon.icns"
else
  print -u2 "Note: ${APP_ICON:t} not found, the volume will use the default disk icon."
fi

rm -f "${DMG_PATH}"
hdiutil create \
  -srcfolder "${CONTENTS_DIR}" \
  -volname "${VOLUME_NAME}" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  -quiet \
  "${READWRITE_DMG}"

mkdir -p "${MOUNT_POINT}"
hdiutil attach "${READWRITE_DMG}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet

# Tell Finder the volume has its own icon. SetFile ships with Xcode; the xattr
# fallback writes the same FinderInfo bit so this works without it.
if [[ -f ${MOUNT_POINT}/.VolumeIcon.icns ]]; then
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "${MOUNT_POINT}"
  else
    xattr -wx com.apple.FinderInfo \
      "0000000000000000040000000000000000000000000000000000000000000000" \
      "${MOUNT_POINT}"
  fi
fi

# Position the two icons so the drag gesture is obvious on first open. Finder
# automation is not available on every machine or CI runner, so a failure here
# only costs the layout, not the disk image.
if ! osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
  tell disk "${VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, 800, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "AirScribe.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT
then
  print -u2 "Note: Finder layout was skipped; the disk image is still valid."
fi

sync
hdiutil detach "${MOUNT_POINT}" -quiet
rmdir "${MOUNT_POINT}"

hdiutil convert "${READWRITE_DMG}" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "${DMG_PATH}"

# An unsigned image warns on download even when the app inside is notarized.
if [[ -n ${AIRSCRIBE_SKIP_DMG_SIGNING:-} ]]; then
  print -u2 "Note: AIRSCRIBE_SKIP_DMG_SIGNING set; the image is unsigned and only fit for local testing."
else
  codesign --sign "${SIGNING_IDENTITY}" --timestamp --force "${DMG_PATH}"
  codesign --verify --strict --verbose=2 "${DMG_PATH}"
fi

if [[ -n ${KEYCHAIN_PROFILE} ]]; then
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
fi

print "${DMG_PATH}"
