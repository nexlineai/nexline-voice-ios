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
- `NexlineCore` (pure Swift, tested on the CI host): `Level`, `LevelStats`, `BargeInDetector`, `Endpointer`
  (end of turn from recognizer results), `SpeechText` (what the voice says, pause tags as silence),
  `SentenceFlusher`, `HeardTimeline` (what the user heard before cutting in), `ChatStreamParser` (serve.py SSE),
  `PCM16Decoder` (xAI audio). Ports of the RN app's `tts.ts`/`llm.ts` logic; keep them tested.
- `NexlineAudio` (iOS only): `VoiceEngine` = one AVAudioEngine with voice processing for the mic and the
  player, so the bot can be interrupted without hearing itself. `SpeechClip` is unused (kept for an
  on-device fallback voice).
- App: `TalkModel` runs the conversation (listen → Nexa → speak → listen, cut-in on the barge-in detector).
  `NexaClient` = serve.py `/chat` on `nexa.nexline.ai` with a Cloudflare Access service token (redirects disabled:
  a rejected token is a 302 to the login page; `/watchdog/version` answers `{"version": N}`). `Keychain` holds the
  keys; only Nexa's token is required, the others have fallbacks. `Settings` = Zé's choices (UserDefaults).
- Speaking: `VoiceChain` = the chosen voice, then xAI → Edge → iPhone. A voice that fails before its first audio
  (error, no key, deadline) hands the same piece on and is skipped for the session; one that fails mid-sentence is
  not replaced. `XAIVoice` (streaming, `ara`), `EdgeVoice` (free, MP3 per piece, decoded via a temp file),
  `DeviceVoice` (SpeechClip; whether `write()` is safe while the voice-processing engine runs is unproven).
- Listening: `MicRouter` hands mic buffers to `DeepgramListener` (Nova-3 streaming, keyterms, `speech_final` /
  `UtteranceEnd` end the turn via `Endpointer.speechEnded`) or `Listener` (iOS 26 SpeechAnalyzer, on-device).
  Deepgram failing at start or mid-session switches to `Listener`. Deepgram results carry their audio end time;
  one that ended before listening began is Nexa's echo and is dropped.
- Enabling voice processing changes the IO formats while the engine is set up, so the engine starts with a
  configuration change pending and stops itself right away (spike builds 1-3). Fixed in build 4: resume the same
  engine (reinstall the tap, prepare, start; no session or voice-processing calls). Never answer a configuration
  change with a new engine. Each start costs one resume, so the resume cap resets on every start.
  The spike app is tagged `spike-audio-build4`. Evidence is in the vault note.
- While Nexa thinks or speaks, recognizer text is ignored (it may be her echo); a turn only counts if the mic
  heard the user above the line, which stops a self-talk loop.
- Playback format is 24 kHz mono float; xAI streams 24 kHz 16-bit PCM, decoded to float.
- Logs use subsystem `com.nexlineai.voice`; read them on Omarchy with `idevicesyslog` over USB.
