cask "airscribe" do
  version "1.0.0"
  sha256 "7e562d89f15ea240e05f4ff05aca00c02d3a2c65d27009b9c04a4e6047d0e8bd"

  url "https://github.com/sourabhsoni0104/airscribe/releases/download/v#{version}/AirScribe-#{version}.dmg"
  name "AirScribe"
  desc "On-device voice dictation for Apple silicon Macs"
  homepage "https://github.com/sourabhsoni0104/airscribe"

  # AirScribe updates itself through Sparkle.
  auto_updates true
  # The app targets macOS 26 and Apple silicon. Builds are also not yet signed
  # with a Developer ID, so macOS refuses to open one unless it was installed
  # with --no-quarantine.
  # A bare `:tahoe` would mean exactly macOS 26 and would stop matching once
  # macOS 27 ships. This is a minimum requirement, so the comparison stays.
  depends_on macos: ">= :tahoe" # rubocop:disable Homebrew/OSDependsOn
  depends_on arch: :arm64

  app "AirScribe.app"

  uninstall quit: "com.airscribe.mac"

  zap trash: [
    "~/Library/Application Support/AirScribe",
    "~/Library/Caches/com.airscribe.mac",
    "~/Library/HTTPStorages/com.airscribe.mac",
    "~/Library/Preferences/com.airscribe.mac.plist",
    "~/Library/Saved Application State/com.airscribe.mac.savedState",
  ]

  caveats <<~EOS
    AirScribe needs two permissions on first launch:

      Microphone, so it can hear you.
      Accessibility, for the hold-to-talk key and for typing text into other apps.

    Its speech model (about 713 MB) downloads on first launch. Until that
    finishes, dictation falls back to Apple's built-in recognition.

    This build is not notarized. If you did not install with --no-quarantine,
    run:

      xattr -dr com.apple.quarantine "#{appdir}/AirScribe.app"

    A saved cloud API key, if you ever set one, lives in the Keychain and is not
    removed by `brew uninstall --zap`. Delete it from inside the app first, under
    Settings, Privacy, "Delete Everything on This Mac".
  EOS
end
