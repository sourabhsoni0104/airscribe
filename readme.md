# AirScribe

Private, on-device voice dictation for Apple-silicon Macs. Hold Control, speak, release — cleaned text lands in the app you were already using.

No account. No telemetry. No transcription server. Speech recognition, cleanup, translation, meeting summaries, and the inline assistant all run locally on your Mac.

- [Requirements](#requirements)
- [Install](#install)
- [First run](#first-run)
- [How to use it](#how-to-use-it)
- [Features](#features)
- [Settings reference](#settings-reference)
- [Where your data lives](#where-your-data-lives)
- [Uninstall](#uninstall)
- [Optional cloud polish (BYOK)](#optional-cloud-polish-byok)
- [Build from source](#build-from-source)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Requirements

| | |
|---|---|
| Mac | Apple silicon (M1 or newer). Intel Macs are not supported. |
| macOS | 26.0 or newer |
| Disk | ~2 GB free for the speech model, ~2.5 GB more if you install the 100+ language pack |
| Network | Needed once, to download the speech model. Dictation works offline afterwards. |
| Apple Intelligence | Optional. Enables deeper writing polish, translation, and meeting summaries. AirScribe works without it. |

## Install

### From a release build

1. Download `AirScribe.zip` from the [Releases page](https://github.com/sourabhsoni0104/airscribe/releases).
2. Double-click the zip to unpack `AirScribe.app`.
3. Drag `AirScribe.app` into your `/Applications` folder.
4. Double-click to launch it. Releases are signed with a Developer ID and notarized by Apple, so it opens normally.

If macOS says the app "cannot be opened because the developer cannot be verified", you downloaded an unsigned build. Right-click the app, choose **Open**, then confirm — or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/AirScribe.app
```

### Verify a download before trusting it

```sh
codesign --verify --strict --verbose=2 /Applications/AirScribe.app
spctl --assess --type execute --verbose=2 /Applications/AirScribe.app
```

Both should report the bundle as accepted with a valid Developer ID signature.

### From source

See [Build from source](#build-from-source).

## First run

AirScribe is a menu-bar app. It has no Dock icon and no main window — look for the waveform icon in your menu bar.

**1. Grant two permissions.** Onboarding walks you through both, and the Privacy pane in Settings shows their live status.

| Permission | Why it is needed | Where macOS asks |
|---|---|---|
| **Microphone** | To hear your dictation | System Settings → Privacy & Security → Microphone |
| **Accessibility** | For the global hold-to-talk shortcut, and to insert text into other apps | System Settings → Privacy & Security → Accessibility |

Screen Recording is requested **only** if you turn on screen-text context or record Mac audio in a meeting. Dictation never needs it.

**2. Let the speech model download.** On first launch AirScribe fetches its on-device model (~713 MB, 6 files) from Hugging Face. Every file is pinned to an exact revision and verified against a SHA-256 hash before use. The download resumes if interrupted, and you can pause it from the menu bar or Settings → Models & Languages.

Until the model finishes, AirScribe falls back to Apple's built-in speech recognition so dictation works immediately.

**3. Optional: install the 100+ language pack** (~1.64 GB) from Settings → Models & Languages, for automatic language detection and mixed-language speech such as Hindi-English code-switching.

## How to use it

**Push to talk** — hold <kbd>Control</kbd>, speak, release. Text is cleaned and inserted where your cursor is.

**Hands-free** — double-press <kbd>Control</kbd> to latch listening on. Press once more to stop.

You can change the trigger to <kbd>Option</kbd>, <kbd>Command</kbd>, or <kbd>Fn</kbd> in Settings → General.

**Pick a writing mode** by clicking the notch panel, or let AirScribe choose automatically per app:

| Mode | What it produces |
|---|---|
| **Email** | Concise professional prose. Never invents greetings, subjects, or sign-offs. |
| **Chat** | Short conversational messages. |
| **Post** | Clear social-post prose. |
| **General** | Plain cleanup, no rewriting. |

**Ask the assistant** by starting your dictation with "AirScribe" or "Hey AirScribe" — for example *"Hey AirScribe, make that more formal"*. Everything else is inserted as literal text, including ordinary sentences that merely contain the word "scribe".

**Record a meeting** from the menu bar, or open `airscribe://meetings`.

### Where text goes when insertion isn't possible

AirScribe verifies that text actually landed before reporting success. If it can't confirm insertion — no editable field is focused, or the app doesn't expose one — it falls back to copying the transcript to your clipboard and tells you so. You can turn that fallback off in Settings → General if you would rather keep your clipboard untouched and see an error instead.

Dictation is refused entirely while a password or other secure field is focused.

## Features

### Dictation

- On-device speech recognition with automatic fallback to Apple's engine while the model installs or if it fails.
- Live partial text while you speak.
- Pause-aware punctuation: sentence and clause boundaries are inferred from your actual speech timing, not guessed from grammar alone.
- Deterministic cleanup — filler words ("um", "you know"), stutters, and self-corrections ("port, I mean put") removed. Idiomatic repeats such as "had had" are preserved.
- Spoken symbols and commands: "at symbol" → `@`, "question mark" → `?`, "full stop" → `.` — while still writing *"full stop"* as words when you are plainly talking about the phrase.
- Context-aware homophone repair for ones/once, there/their/they're, your/you're, its/it's, to/too.
- Direct speech gets quotation marks automatically.
- Optional deeper polish through Apple Intelligence, on-device.
- Insert immediately and safely replace once polish finishes, or wait for the polished version — your choice.

### Languages

- Dictate in your chosen locale, or use `auto` for automatic detection with the language pack installed.
- Output in the original language, transliterated Romanized Hindi, or translated to English on-device.
- Transliteration is deterministic and never silently becomes translation: Latin text and English words pass through unchanged.
- Generated translation and polish are validated before they replace what you said — output that drops names, numbers, or a large share of your words is discarded in favour of the original.

### Learning and vocabulary

- Custom vocabulary you control, with correct capitalization preserved and split words rejoined ("air scribe" → "AirScribe").
- Optional learning from your corrections: fix a misheard name once in the same field and AirScribe remembers it. Rules keyed on everyday words are never learned, so correcting one "to" cannot rewrite your future dictation. Retained rules are capped and evictable, and every one is listed and individually deletable in Settings.

### Modes and per-app behaviour

- Four writing modes with fully editable instructions, resettable to defaults.
- Per-app mode mappings — e.g. Mail always uses Email mode, Slack always uses Chat.

### Meetings

- Records your microphone and your Mac's own audio as separate, speaker-labelled tracks.
- Live source-labelled transcript while recording.
- Timed transcripts with local summaries covering Overview, Decisions, and Action items. Long meetings are summarised in segments and merged, so nothing is dropped for length.
- Export as TXT, Markdown, or SRT subtitles.
- Recordings stop automatically after four hours, and won't start without enough free disk space.
- Falls back to microphone-only if Mac audio capture is unavailable.

### Context and assistant (opt-in, off by default)

- Optionally share the active app, window title, focused text, clipboard, and on-screen text (OCR) with the local cleanup pass, to spell names correctly.
- Per-app exclusion list.
- Context capture is skipped in secure fields, and skipped whenever the focused control cannot be positively identified as safe.
- "Hey AirScribe" inline assistant, answering from your recent dictation and local context.
- Captured context is **never** sent to the cloud, even with cloud polish enabled.

### History

- Searchable local history with the raw and cleaned text, engine used, and latency.
- Replay the original audio, copy, export, delete individually, or delete everything.

### App and system integration

- Menu-bar app with a hardware-aligned notch panel that stays collapsed while idle.
- Launch at login.
- Interrupted-recording recovery: if AirScribe is killed mid-dictation, the audio is preserved and offered on next launch.
- Automatic signed updates over HTTPS with EdDSA signature verification.
- Hardened Runtime, owner-only file permissions on all recordings and transcripts, and API keys in the Keychain.

## Settings reference

Open Settings from the menu bar. Nine panes:

| Pane | Contents |
|---|---|
| **General** | Default mode, locale, output language, hotkey, polish behaviour, clipboard-fallback behaviour |
| **Writing Modes** | Per-mode instructions and per-app mappings |
| **Vocabulary** | Your terms, plus every learned correction with individual delete |
| **Models & Languages** | Speech model status, pause/resume, folder reveal, 100+ language pack install/remove |
| **Context & Assistant** | Context sources, per-app exclusions, "Hey AirScribe" toggle |
| **History** | Search, replay, copy, export, delete |
| **BYOK Polish** | Optional cloud provider, model ID, API key |
| **Privacy** | Permission status and "Delete Everything on This Mac" |
| **App & Updates** | Launch at login, update checks, recovered recordings |

## Where your data lives

Everything is local, under your own account:

| What | Path |
|---|---|
| Dictation history and audio | `~/Library/Application Support/AirScribe/history.json`, `~/Library/Application Support/AirScribe/audio/` |
| Meeting transcripts and audio | `~/Library/Application Support/AirScribe/meetings.json`, `~/Library/Application Support/AirScribe/MeetingAudio/` |
| Vocabulary, learned corrections, mode instructions | `~/Library/Application Support/AirScribe/preferences.json` |
| Downloaded models | `~/Library/Application Support/AirScribe/models/` |
| Other settings | `~/Library/Preferences/com.airscribe.mac.plist` |
| Cloud API key (only if you set one) | macOS Keychain, service `com.airscribe.mac.cloud-polish` |
| Temporary audio buffers | `$TMPDIR/AirScribe/TranscriptionBuffers/` |

Recordings, transcripts, and anything containing your own words are written with owner-only permissions (`0600`, in `0700` directories).

## Uninstall

### Step 1 — delete your data from inside the app

Open **Settings → Privacy → Delete Everything on This Mac…** and confirm.

This removes dictation history, meeting transcripts and audio, custom vocabulary, learned corrections, every downloaded model file, the saved API key from your Keychain, and all settings. It also turns off launch at login. If anything cannot be removed, AirScribe tells you exactly what remained.

Do this **before** deleting the app — it is the only step that clears the Keychain item and the login item for you.

### Step 2 — remove the app

Quit AirScribe from the menu bar, then drag `/Applications/AirScribe.app` to the Trash.

### Step 3 — optional cleanup

If you skipped step 1, or want to be certain nothing is left:

```sh
# Data, models, and cached transcription buffers
rm -rf ~/Library/Application\ Support/AirScribe
rm -rf "${TMPDIR}AirScribe"

# Settings
defaults delete com.airscribe.mac 2>/dev/null
rm -f ~/Library/Preferences/com.airscribe.mac.plist

# Saved cloud API key, if you ever set one
security delete-generic-password -s com.airscribe.mac.cloud-polish 2>/dev/null

# Updater state
rm -rf ~/Library/Caches/com.airscribe.mac
rm -rf ~/Library/Application\ Support/Caches/com.airscribe.mac
```

Then revoke the permissions macOS remembers:

```sh
tccutil reset Microphone com.airscribe.mac
tccutil reset Accessibility com.airscribe.mac
tccutil reset ScreenCapture com.airscribe.mac
```

If a stale entry remains, remove AirScribe by hand from System Settings → Privacy & Security → Accessibility / Microphone / Screen Recording, and from General → Login Items.

## Optional cloud polish (BYOK)

Off by default, and entirely optional — AirScribe is fully functional without it. When you enable it with your own API key:

- Only **transcript text** is sent. Microphone audio is never uploaded.
- Captured context — clipboard, screen text, focused text — is never sent.
- HTTPS is required. Redirects are refused. URLs carrying embedded credentials are rejected.
- Requests are not cached or stored, and are sent with `store: false`.
- Your key is kept in the Keychain with device-only data protection, never in a file or plist.
- Sending a key to a host that is not a recognised provider requires explicit confirmation first, so a typo in the endpoint cannot leak it.
- A truncated or content-dropping response is discarded and your on-device text is used instead.
- A provider outage never blocks dictation.

Set it up in Settings → BYOK Polish: enter an HTTPS endpoint (OpenAI Responses API shape), a model ID, and your key.

## Build from source

Requirements: Xcode 26.3+, macOS 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/sourabhsoni0104/airscribe.git
cd airscribe/app
xcodegen generate
open AirScribe.xcodeproj
```

Select the `AirScribe` scheme and **My Mac**, then Run.

The Xcode project is generated from `app/project.yml` — edit that file and rerun `xcodegen generate` rather than hand-editing the project.

### Run the tests

```sh
cd app
xcodebuild -project AirScribe.xcodeproj -scheme AirScribe \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO test
```

The model runtime integration test skips itself unless the downloaded model files are present locally.

### Build an unsigned app for local use

```sh
cd app
xcodebuild -project AirScribe.xcodeproj -scheme AirScribe \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/local build
open build/local/Build/Products/Release
```

### Ship a signed, notarized release

The updater's public key and HTTPS appcast URL are compiled into the app; the private signing key stays in your Keychain. Developer ID and notarization credentials are supplied through the environment or CI secrets and are never committed.

```sh
cd app
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
AIRSCRIBE_CODE_SIGN_IDENTITY="Developer ID Application" \
  zsh Scripts/build-release.sh

zsh Scripts/notarize-release.sh /path/to/AirScribe.app YOUR_NOTARYTOOL_PROFILE

AIRSCRIBE_DOWNLOAD_URL_PREFIX=https://github.com/OWNER/REPO/releases/download/v1.0.0/ \
  zsh Scripts/generate-appcast.sh /path/to/release-directory
```

`build-release.sh` refuses to ship a build with debug entitlements or debug dylibs present. `Config/Release.xcconfig.example` documents the non-secret build values.

## Troubleshooting

**The hotkey does nothing.** Accessibility permission is missing or was reset by an app update. Open Settings → Privacy and re-grant it; AirScribe re-arms the shortcut as soon as it is granted.

**Text is copied to the clipboard instead of inserted.** The focused field could not be confirmed as an editable, non-secure text area. This is deliberate — see [Where text goes when insertion isn't possible](#where-text-goes-when-insertion-isnt-possible).

**Nothing is inserted and an error mentions secure input.** A password field or an app holding secure input has focus. Dictation is blocked there by design.

**"An AirScribe Models file failed its integrity check."** A download was corrupted or intercepted. Use Resume in Settings → Models & Languages; the file is re-fetched and re-verified.

**Model download will not start.** Check free disk space — installation requires the remaining download plus 1 GB of headroom.

**Meeting recorded no Mac audio.** Grant Screen Recording permission, which macOS requires for system-audio capture. AirScribe records microphone-only without it and says so in the meeting window.

**Dictation stops early after switching headphones.** Changing input device mid-recording changes the sample rate; AirScribe keeps the audio captured before the switch rather than corrupting the whole recording. Stop and start again after switching devices.

## Privacy

No account. No telemetry. No transcription server. Your audio, transcripts, settings, vocabulary, and models never leave your Mac unless you explicitly enable BYOK polish, which sends transcript text only.

Report a vulnerability privately through [GitHub Security Advisories](https://github.com/sourabhsoni0104/airscribe/security/advisories/new). See [SECURITY.md](SECURITY.md).

## License

MIT for AirScribe's source code. Third-party frameworks and downloaded model assets retain their respective licenses.
