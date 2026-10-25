# CLAUDE.md

Native iPhone app for the Nexline voice agents, replacing the Expo app `nexline-voice-app`.
Plan, decisions and the feature cut-list are in the vault:
`04_projects/nexa/notes/2026-10-21-native-apps-roadmap.md`, section "25 Oct 2026". Read it before changing scope.

## Repo rules
- **Public repo** `nexlineai/nexline-voice-ios`, all rights reserved (`LICENSE`), not open source.
- **No keys in the binary or the repo.** API keys are entered on the phone and stored in the Keychain.
- **The signing key exists only in the `testflight` environment** (maintainer approval, `v*` tags).
  No repo-level secrets, ever. Never use `pull_request_target`.
- Check `.github/workflows/` before every push (exfil-workflow history on other repos).
- Commits use `58702721+nexlineai@users.noreply.github.com` (set in this clone's git config).
- Nothing builds on Omarchy (no Xcode, and too little disk for a Swift toolchain). CI is the compiler.
  On failure, read the annotations without a token:
  `curl -s https://api.github.com/repos/nexlineai/nexline-voice-ios/check-runs/<id>/annotations`.

## Build
- `project.yml` → `xcodegen generate` → `NexlineVoice.xcodeproj` (gitignored, never hand-edited).
- Deployment target iOS 26.0, iPhone only. Swift 5 language mode for now.
- `CURRENT_PROJECT_VERSION` comes from the workflow run number; a TestFlight tag must match
  `MARKETING_VERSION` (`v0.1.0`, or `v0.1.0-2` for another build of it).

## Architecture
- `NexlineCore` (pure Swift, tested): `Level`, `LevelStats`, `BargeInDetector`.
- `NexlineAudio` (iOS only): `VoiceEngine` = one AVAudioEngine with voice processing for the mic and the
  player, so the bot can be interrupted without hearing itself. `SpeechClip` renders on-device speech
  (unused since build 3; the spike plays the bundled espeak-ng `App/test-clip.wav`).
- Open problem (builds 1-3): enabling voice processing changes the IO formats while the engine is set up, so the
  engine starts with a configuration change pending and stops itself right away. It is not the speech synthesizer
  (build 2) and not the session mode, A2DP or sample rate (build 3, all four setups fail the same way). Rebuilding the
  engine re-enables voice processing and loops. Build 4 resumes the same engine instead (reinstall the tap, prepare,
  start; no session or voice-processing calls). Never answer a configuration change with a new engine. Evidence is
  in the vault note.
- Playback format is 24 kHz mono float, the format xAI streams.
- Logs use subsystem `com.nexlineai.voice`; read them on Omarchy with `idevicesyslog` over USB.
