#!/bin/zsh
set -euo pipefail

# Signs a built AirScribe.app so macOS keeps its Accessibility permission.
#
# Why this exists: building with CODE_SIGNING_ALLOWED=NO leaves a linker-signed
# binary whose signing identifier is "AirScribe" rather than the bundle
# identifier, and whose designated requirement is nothing but the binary's
# cdhash. macOS pins the Accessibility grant to that requirement, so every
# rebuild silently invalidates it: the switch in System Settings still looks on,
# while AXIsProcessTrusted() returns false. `tccutil reset` also misses, because
# it matches on the signing identifier.
#
# Signing with any stable certificate replaces the cdhash requirement with one
# anchored to that certificate, and the grant then survives updates.
#
# Usage: sign-app.sh <AirScribe.app>
#
#   AIRSCRIBE_CODE_SIGN_IDENTITY   Certificate to use. Defaults to "-", ad-hoc.
#
# Ad-hoc signing fixes the identifier but cannot give a stable requirement, so
# permissions still need re-granting after an update. For a build whose
# permissions stick without paying for a Developer ID, make a self-signed
# code-signing certificate once and use it every time:
#
#   Keychain Access > Certificate Assistant > Create a Certificate
#     Name: AirScribe Local
#     Identity Type: Self Signed Root
#     Certificate Type: Code Signing
#
#   AIRSCRIBE_CODE_SIGN_IDENTITY="AirScribe Local" zsh Scripts/sign-app.sh path/to/AirScribe.app
#
# That is free, and as long as the same certificate is reused the requirement
# stays put. It does not help Gatekeeper, which still needs a Developer ID and
# notarization.

if (( $# != 1 )); then
  print -u2 "Usage: sign-app.sh <AirScribe.app>"
  exit 1
fi

APP_PATH=${1:A}
SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
ENTITLEMENTS=${APP_DIR}/Config/AirScribe.entitlements
IDENTITY=${AIRSCRIBE_CODE_SIGN_IDENTITY:--}

if [[ ! -d ${APP_PATH} ]]; then
  print -u2 "No app bundle at ${APP_PATH}."
  exit 1
fi
if [[ ! -f ${ENTITLEMENTS} ]]; then
  print -u2 "Entitlements not found at ${ENTITLEMENTS}."
  exit 1
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "${APP_PATH}/Contents/Info.plist")
if [[ -z ${BUNDLE_ID} ]]; then
  print -u2 "Could not read CFBundleIdentifier from the bundle."
  exit 1
fi

# Nested code has to be signed before the bundle that contains it.
for framework in "${APP_PATH}"/Contents/Frameworks/*(N); do
  codesign --force --sign "${IDENTITY}" --timestamp=none --options runtime "${framework}"
done

codesign --force --sign "${IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  --options runtime \
  --entitlements "${ENTITLEMENTS}" \
  "${APP_PATH}"

codesign --verify --strict "${APP_PATH}"

print "Signed ${APP_PATH:t} as ${BUNDLE_ID}"
print -n "Designated requirement: "
codesign -d --requirements - "${APP_PATH}" 2>&1 | sed -n 's/^# designated => //p'

if [[ ${IDENTITY} == "-" ]]; then
  print -u2 ""
  print -u2 "Note: ad-hoc signed. The identifier is correct, so tccutil works, but"
  print -u2 "the requirement is still this build's cdhash. macOS will drop the"
  print -u2 "Accessibility permission on the next update. Use a self-signed or"
  print -u2 "Developer ID certificate to make it stick; see the notes in this script."
fi
