# Releasing AirScribe

The exact steps that ship a version, in order. Following them keeps the download
button, the Homebrew cask, and the update feed pointing at the same build.

## 1. Bump the version

In `app/project.yml`, raise `MARKETING_VERSION` and increment
`CURRENT_PROJECT_VERSION`, then regenerate the project:

```sh
cd app
xcodegen generate
```

## 2. Build and test

```sh
xcodebuild -project AirScribe.xcodeproj -scheme AirScribe \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test

xcodebuild -project AirScribe.xcodeproj -scheme AirScribe \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

## 3. Sign and package

Sign so macOS keeps the Accessibility permission across the update, then build the
disk image and the Sparkle zip. With a Developer ID, notarize first.

```sh
# Signed with any stable certificate, so permissions persist. See sign-app.sh.
zsh Scripts/sign-app.sh /path/to/Release/AirScribe.app

zsh Scripts/make-dmg.sh /path/to/Release/AirScribe.app
ditto -c -k --keepParent /path/to/Release/AirScribe.app AirScribe-<version>.zip
```

The disk image comes out as `AirScribe-<version>.dmg`. Make a second copy named
`AirScribe.dmg`: the website's download button uses the stable URL
`releases/latest/download/AirScribe.dmg`, so that unversioned copy must be on every
release.

```sh
cp AirScribe-<version>.dmg AirScribe.dmg
shasum -a 256 AirScribe-<version>.dmg AirScribe-<version>.zip > SHA256SUMS.txt
```

## 4. Tag and publish

```sh
git commit -am "release: <version>"
git tag v<version>
git push origin main --tags

gh release create v<version> \
  AirScribe-<version>.dmg AirScribe-<version>.zip AirScribe.dmg SHA256SUMS.txt \
  --title "AirScribe <version>" --notes-file notes.md
```

Leave off `--prerelease` for a normal release, so `releases/latest` resolves to it
and the website download link works. If a release was published as a prerelease,
promote it:

```sh
gh release edit v<version> --prerelease=false --latest
```

## 5. Point the cask at it

In `Casks/airscribe.rb`, set `version` to the new number and `sha256` to the
disk image's checksum from `SHA256SUMS.txt`, then:

```sh
brew style Casks/airscribe.rb
git commit -am "cask: <version>"
git push
```

## 6. Update the appcast, once signing exists

`generate_appcast` refuses to sign an ad-hoc build, so the update feed can only be
produced from a properly signed app. With a Developer ID in place:

```sh
AIRSCRIBE_DOWNLOAD_URL_PREFIX=https://github.com/OWNER/REPO/releases/download/v<version>/ \
  zsh Scripts/generate-appcast.sh /path/to/folder
```

Commit the regenerated `appcast.xml`. Until then, updates are manual downloads.

## What each URL is for

| URL | Used by |
|---|---|
| `releases/latest/download/AirScribe.dmg` | The website download button. Never changes. |
| `releases/download/v<version>/AirScribe-<version>.dmg` | Direct link to one specific version. |
| `AirScribe-<version>.zip` | Sparkle's update feed. |
| `SHA256SUMS.txt` | Anyone verifying a download. |
