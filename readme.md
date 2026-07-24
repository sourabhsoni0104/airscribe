# AirScribe

Voice dictation for Macs that runs entirely on your own machine. Hold Control, say what you want written, let go. The cleaned-up text appears wherever your cursor was.

No account, no subscription, no server. Speech recognition, text cleanup, translation, meeting summaries, and the built-in assistant all run locally.

## Contents

- [What you need](#what-you-need)
- [Installing](#installing)
- [First launch](#first-launch)
- [Using it](#using-it)
- [What it can do](#what-it-can-do)
- [Settings](#settings)
- [Where your files go](#where-your-files-go)
- [Uninstalling](#uninstalling)
- [Cloud polish, if you want it](#cloud-polish-if-you-want-it)
- [Building it yourself](#building-it-yourself)
- [When something goes wrong](#when-something-goes-wrong)
- [License](#license)

## What you need

A Mac with Apple silicon (M1 or later) running macOS 26 or newer. Intel Macs won't work.

You'll want about 2 GB of free disk space for the speech model, plus another 2.5 GB if you later add the optional 100+ language pack. An internet connection is needed once, to fetch the model. After that, dictation works offline.

Apple Intelligence is optional. If you have it turned on, AirScribe can use it for deeper rewriting, translation, and meeting summaries. Everything else works without it.

## Installing

> Current builds are **not signed or notarized**, because that needs a paid Apple Developer account. The app is fine, but macOS has no way to confirm who built it, so it needs one extra step to open. See [Installing an unsigned build](#installing-an-unsigned-build).

### With Homebrew

```sh
brew tap sourabhsoni0104/airscribe https://github.com/sourabhsoni0104/airscribe
brew install --cask --no-quarantine sourabhsoni0104/airscribe/airscribe
```

`--no-quarantine` is what keeps macOS from blocking an unsigned app, so don't leave it off. Later:

```sh
brew upgrade --cask airscribe
brew uninstall --cask airscribe          # leaves your transcripts and settings alone
brew uninstall --zap --cask airscribe    # also removes data, models, and settings
```

### From the disk image

1. Download `AirScribe-1.0.0.dmg` from the [Releases page](https://github.com/sourabhsoni0104/airscribe/releases).
2. Open it. A window appears with AirScribe on the left and your Applications folder on the right.
3. Drag AirScribe onto Applications.
4. Eject the disk image, then follow the unsigned-build step below before launching.

The app is about 43 MB. It contains no speech models; those get downloaded later, onto your machine, and you can delete them whenever you like.

### Installing an unsigned build

macOS will say it cannot verify the app is free of malware. Pick whichever of these suits you:

1. Install with Homebrew and `--no-quarantine`, as above. Nothing else to do.
2. Clear the quarantine flag yourself, then open the app normally:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AirScribe.app
   ```

3. Try to open it, let macOS refuse, then go to System Settings, Privacy & Security, scroll down to the message about AirScribe, and click Open Anyway. Right-clicking and choosing Open stopped working for this in macOS 15, so don't bother with that.

One thing to know before you settle on an unsigned build: macOS ties Accessibility permission to an app's signing identity, and AirScribe needs Accessibility for its hotkey and for typing into other apps. Without a stable identity that permission can be dropped when the app updates, and you would grant it again in System Settings. Nothing breaks for good, but signed builds don't have this problem.

If you would rather avoid all of it, build from source. Apps you compile yourself are never quarantined.

Once builds are signed, you'll be able to check one before trusting it:

```sh
codesign --verify --strict --verbose=2 /Applications/AirScribe.app
spctl --assess --type execute --verbose=2 /Applications/AirScribe.app
```

## First launch

AirScribe lives in your menu bar. There's no Dock icon and no main window, so look for the waveform in the menu bar.

You'll be asked for two permissions. Onboarding walks you through both, and the Privacy pane in Settings always shows where you stand.

| Permission | Why |
|---|---|
| Microphone | To hear you |
| Accessibility | For the global hold-to-talk key, and to type text into other apps |

Screen Recording is only requested if you turn on screen-text context or record your Mac's audio during a meeting. Plain dictation never needs it.

The speech model downloads on first launch. It's roughly 713 MB across six files, each pinned to an exact revision and checked against a SHA-256 hash before AirScribe will use it. If the download is interrupted it picks up where it left off, and you can pause it from the menu bar or from Settings.

While that's happening, dictation still works. AirScribe falls back to Apple's built-in speech recognition until its own model is ready.

Later, if you want automatic language detection or you speak more than one language in a sentence (Hindi and English mixed together, say), install the 100+ language pack from Settings. It's about 1.64 GB.

## Using it

Hold Control, talk, release. That's the whole thing.

If you'd rather not hold the key down, press Control twice quickly to keep listening, then press it again to stop. You can switch the trigger to Option, Command, or Fn in Settings.

Click the notch panel to pick a writing mode, or set up per-app rules and let AirScribe choose:

| Mode | What you get |
|---|---|
| Email | Tightened prose, wrapped in a greeting and sign-off that match how the message reads. |
| Chat | Short and conversational. |
| Post | Clear prose suitable for posting. |
| General | Cleanup only, no rewriting. |

Start a sentence with "AirScribe" or "Hey AirScribe" to talk to the assistant instead of dictating. For example, "Hey AirScribe, make that more formal." Anything else gets typed out as-is, including ordinary sentences that happen to contain the word scribe.

To record a meeting, use the menu bar or open `airscribe://meetings`.

### When text can't be inserted

AirScribe checks that text actually landed before it claims success. If it can't confirm that (nothing editable is focused, or the app doesn't expose its text field), it copies the transcript to your clipboard and tells you it did that.

That overwrites whatever you had copied, so there's a switch in Settings to turn the fallback off. With it off you get an error instead and your clipboard is left alone.

Dictation is refused outright while a password field has focus.

## What it can do

**Dictation.** Runs on-device, and falls back to Apple's engine while the model installs or if it fails. You see partial text as you speak. Punctuation comes from your actual pauses rather than guesswork, so where you stop talking is where the sentence ends. Filler words go away ("um", "you know"), as do stutters and spoken corrections like "port, I mean put". Phrases that are genuinely repeated, "had had" for instance, are left alone.

Say "at symbol" and you get `@`. Same for question marks, full stops, and the rest. If you're plainly talking *about* the phrase, as in "print the words full stop", it stays as words.

Homophones get sorted out from context: ones and once, there and their and they're, your and you're, its and it's, to and too. Direct speech picks up quotation marks on its own.

If you restart a phrase halfway through and leave an article stranded, as in "the it shouldn't be hardcoded", the leftover word is dropped so the sentence reads properly.

**Email mode writes the wrapper for you.** Dictating an email gives you the body, and adding the greeting and sign-off by hand afterwards is the tedious part. AirScribe reads how the message sounds and matches it:

| Your message sounds | You get |
|---|---|
| Casual: "quick question, can we meet today" | "Hi," at the top, "Regards," at the bottom |
| Formal: "kindly review the attached proposal at your earliest convenience" | "Dear Sir/Madam," at the top, "Thanking you," and "Yours sincerely," at the bottom |

If you dictate your own greeting or sign-off, that is left exactly as you said it, and only the missing half is added. No recipient name is ever invented, since AirScribe has no way of knowing it. When the register is unclear the casual wrapper is used, because "Hi" reads fine in a formal thread while "Dear Sir/Madam" on a quick note to a colleague does not. Turn the whole thing off under Settings, General, Email mode.

If Apple Intelligence is available you can turn on a deeper rewriting pass, still on-device. You choose whether AirScribe inserts immediately and quietly replaces the text once polish finishes, or waits and inserts the finished version once.

**Languages.** Dictate in whatever locale you pick, or use `auto` with the language pack installed. Output can stay in the original language, come out as Romanized Hindi, or be translated to English locally. Transliteration is deterministic and never turns into translation, so English words pass straight through.

Anything a language model produces gets checked before it replaces your words. If a rewrite or translation loses names, numbers, or a big chunk of what you said, it's thrown away and you keep the original.

**Vocabulary and learning.** Add terms you use and AirScribe keeps their capitalization and rejoins them when the recognizer splits them ("air scribe" becomes "AirScribe").

It can also learn from your corrections: fix a misheard name once, in the same field, and it remembers. That learning is deliberately narrow, because a rule that fires everywhere is worse than no rule at all.

- Everyday words are never learned as keys. Changing a single "to" or "our" teaches nothing, so it can't come back to haunt every later sentence.
- A misheard name or piece of jargon ("cadence" to "Kadenze") is a transcription fix, so it applies everywhere.
- A shortening or a style tweak ("our" to "r" for a forum post) stays in the app you taught it in. Your habits on one site don't follow you into your email.
- Everything learned is listed in Settings with the app it applies to, and you can delete entries one at a time. Nothing is hidden from you.

**Modes and per-app rules.** Four modes, each with instructions you can edit and reset. Map apps to modes so Mail always uses Email and Slack always uses Chat.

**Meetings.** Records your microphone and your Mac's own audio as two separate labelled tracks, with a live transcript as it goes. You get a timed transcript and a local summary covering overview, decisions, and action items. Long meetings are summarized in pieces and then merged, so nothing gets dropped for being too long. Export as TXT, Markdown, or SRT subtitles. Recording stops on its own after four hours, and won't start if the disk is nearly full. If your Mac's audio can't be captured, it records the microphone only and says so.

**Context and the assistant.** Off by default. If you turn it on, AirScribe can look at the active app, window title, focused text, clipboard, and text on screen, and use that to spell names correctly. There's a per-app exclusion list. It skips secure fields, and skips anything it can't positively identify as safe. The "Hey AirScribe" assistant answers from your recent dictation and this local context. None of it is ever sent to the cloud, even if cloud polish is on.

**History.** Everything you dictate is searchable locally, with the raw text, the cleaned text, which engine ran, and how long it took. You can replay the original audio, copy, export, delete one entry, or delete the lot.

**System bits.** Menu bar app with a notch panel that stays out of the way when idle. Launch at login. If AirScribe is killed mid-recording, the audio is kept and offered to you next time you open it. Updates arrive automatically over HTTPS with signature checking. Hardened Runtime is on, recordings and transcripts are readable only by you, and API keys live in the Keychain.

## Settings

Nine panes, reachable from the menu bar.

| Pane | What's in it |
|---|---|
| General | Default mode, locale, output language, hotkey, polish behaviour, clipboard fallback |
| Writing Modes | Per-mode instructions, per-app mappings |
| Vocabulary | Your terms, and every learned correction with a delete button |
| Models & Languages | Model status, pause and resume, reveal folder, language pack |
| Context & Assistant | Context sources, app exclusions, assistant toggle |
| History | Search, replay, copy, export, delete |
| BYOK Polish | Optional cloud provider, model ID, API key |
| Privacy | Permission status, and Delete Everything on This Mac |
| App & Updates | Launch at login, update checks, recovered recordings |

## Where your files go

All of it sits under your own account:

| What | Where |
|---|---|
| Dictation history and audio | `~/Library/Application Support/AirScribe/history.json` and `audio/` |
| Meeting transcripts and audio | `~/Library/Application Support/AirScribe/meetings.json` and `MeetingAudio/` |
| Vocabulary, learned corrections, mode instructions | `~/Library/Application Support/AirScribe/preferences.json` |
| Downloaded models | `~/Library/Application Support/AirScribe/models/` |
| Other settings | `~/Library/Preferences/com.airscribe.mac.plist` |
| Cloud API key, if you set one | Keychain, service `com.airscribe.mac.cloud-polish` |
| Temporary audio buffers | `$TMPDIR/AirScribe/TranscriptionBuffers/` |

Recordings, transcripts, and anything else containing your words are written so only your account can read them (mode 0600, inside 0700 directories).

## Uninstalling

**Start inside the app.** Open Settings, go to Privacy, and click "Delete Everything on This Mac".

That clears dictation history, meeting transcripts and audio, vocabulary, learned corrections, every downloaded model, your saved API key in the Keychain, and all settings. It also turns off launch at login. If anything can't be removed, AirScribe tells you exactly what's left.

Do this before you delete the app. It's the only step that handles the Keychain entry and the login item for you.

**Then remove the app.** Quit AirScribe from the menu bar and drag `/Applications/AirScribe.app` to the Trash.

**If you skipped the first step,** or you want to be certain nothing remains:

```sh
rm -rf ~/Library/Application\ Support/AirScribe
rm -rf "${TMPDIR}AirScribe"
defaults delete com.airscribe.mac 2>/dev/null
rm -f ~/Library/Preferences/com.airscribe.mac.plist
security delete-generic-password -s com.airscribe.mac.cloud-polish 2>/dev/null
rm -rf ~/Library/Caches/com.airscribe.mac
```

Then take back the permissions macOS is holding:

```sh
tccutil reset Microphone com.airscribe.mac
tccutil reset Accessibility com.airscribe.mac
tccutil reset ScreenCapture com.airscribe.mac
```

If a stale entry hangs around, remove AirScribe by hand from System Settings under Privacy & Security (Accessibility, Microphone, Screen Recording) and from General, Login Items.

## Cloud polish, if you want it

This is off by default and completely optional. AirScribe does not need it. If you turn it on with your own API key, here's exactly what happens:

Only transcript text is sent. Your microphone audio never leaves the machine, and neither does captured context like your clipboard or what's on screen. HTTPS is required, redirects are refused, and a URL with credentials embedded in it is rejected. Requests are sent with `store: false` and aren't cached anywhere.

Your key is kept in the Keychain with device-only protection, never in a file or a plist. If the endpoint you enter isn't a host AirScribe recognizes, it will not send your key until you confirm that host by hand, so a typo can't leak it. If a response comes back truncated or missing part of what you said, it's discarded and your local text is used instead. A provider being down never blocks dictation.

Set it up under Settings, BYOK Polish: an HTTPS endpoint using the OpenAI Responses API shape, a model ID, and your key.

## Building it yourself

You'll need Xcode 26.3 or newer, macOS 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/sourabhsoni0104/airscribe.git
cd airscribe/app
xcodegen generate
open AirScribe.xcodeproj
```

Pick the AirScribe scheme and My Mac, then Run.

The Xcode project is generated from `app/project.yml`. Edit that and re-run `xcodegen generate` rather than editing the project file directly.

Tests:

```sh
cd app
xcodebuild -project AirScribe.xcodeproj -scheme AirScribe \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO test
```

The model runtime test skips itself unless the downloaded model files are on the machine.

An unsigned build you can run locally:

```sh
cd app
xcodebuild -project AirScribe.xcodeproj -scheme AirScribe \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

### Cutting a release

The updater's public key and appcast URL are compiled into the app. The private signing key stays in your Keychain, and Developer ID and notarization credentials come from the environment or from CI secrets. None of that is committed.

```sh
cd app
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
AIRSCRIBE_CODE_SIGN_IDENTITY="Developer ID Application" \
  zsh Scripts/build-release.sh

zsh Scripts/notarize-release.sh /path/to/AirScribe.app YOUR_NOTARYTOOL_PROFILE
zsh Scripts/make-dmg.sh /path/to/AirScribe.app YOUR_NOTARYTOOL_PROFILE

AIRSCRIBE_DOWNLOAD_URL_PREFIX=https://github.com/OWNER/REPO/releases/download/v1.0.0/ \
  zsh Scripts/generate-appcast.sh /path/to/release-directory
```

`build-release.sh` refuses to ship a build that still has debug entitlements or debug dylibs in it. `make-dmg.sh` produces the drag-to-install disk image, signs it, and notarizes it if you pass a profile. Attach the `.dmg` to the GitHub release for people to download, and keep the `.zip` too, because that's what Sparkle reads for automatic updates. `Config/Release.xcconfig.example` lists the non-secret build values.

## When something goes wrong

**The hotkey does nothing.** Accessibility permission is missing, or an app update reset it. Re-grant it in Settings under Privacy. AirScribe re-arms the shortcut the moment it's granted.

**Text keeps landing on the clipboard.** AirScribe couldn't confirm the focused field was an editable, non-secure text area, so it took the safe route. See [When text can't be inserted](#when-text-cant-be-inserted).

**An error mentions secure input.** A password field has focus, or an app is holding secure input. Dictation is blocked there deliberately.

**"An AirScribe Models file failed its integrity check."** A download was corrupted or tampered with. Hit Resume in Settings under Models & Languages and the file is fetched and verified again.

**The model download won't start.** Check free space. Installing needs the remaining download plus 1 GB of headroom.

**A meeting captured no Mac audio.** Grant Screen Recording, which macOS requires for system audio. Without it you get a microphone-only recording, and the meeting window says so.

**Dictation stopped early after switching headphones.** Changing input device mid-recording changes the sample rate. AirScribe keeps the audio from before the switch instead of corrupting the whole recording. Stop and start again after changing devices.

## Privacy

No account, no telemetry, no transcription server. Your audio, transcripts, settings, vocabulary, and models stay on your Mac unless you deliberately turn on BYOK polish, which sends transcript text and nothing else.

Found a security problem? Please report it privately through [GitHub Security Advisories](https://github.com/sourabhsoni0104/airscribe/security/advisories/new) rather than a public issue. Details in [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE). Third-party frameworks and downloaded model files keep their own licenses.
