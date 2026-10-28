# CLAUDE.md

Native iPhone app for the Nexline voice agents, replacing the Expo app `nexline-voice-app`.
Plan, decisions and the feature cut-list are in the vault:
`04_projects/nexa/notes/2026-10-21-native-apps-roadmap.md`, section "25 Oct 2026". Read it before changing scope.

## Repo rules
- **Public repo** `nexlineai/nexline-voice-ios`, all rights reserved (`LICENSE`), not open source.
- **No keys in the binary or the repo.** API keys are entered on the phone and stored in the Keychain.
- **The signing key exists only in the `testflight` environment** (maintainer approval, `v*` tags).
  No repo-level secrets, ever. Never use `pull_request_target`.
- **No hardcoded words to fix a mishearing** (Zé, 28 Oct). This is a production app sold with the kiosk, so personal
  names or extra keyterms never get baked in. The ZDB and service-name keyterms of builds 15-17 were removed in 18.
  Fix recognition at the STT or settings level.
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
- Speaking: `VoiceChain` = the chosen voice, then xAI → Deepgram → iPhone. A voice that fails before its first audio
  (error, no key, deadline) hands the same piece on and is skipped for the session; one that fails mid-sentence is
  not replaced. `XAIVoice` (streaming, `ara`), `DeepgramVoice` (Aura-2 Thalia,
  Speak + Flush per piece), `DeviceVoice` (SpeechClip; build 8 showed `write()` is safe while the voice-processing
  engine runs). Edge was dropped (27 Oct): Microsoft's read-aloud now wants a Sec-MS-GEC v2 token (403 with v1).
- Conversation: `TalkModel` keeps the shared serve.py history (`GET /history`, every 4 s while on screen, never
  during a turn, not with fewer messages than shown right after one). Typed messages are turns too: with voice
  on they cut in and get spoken, with voice off the reply is text only. `ReplyBlocks` (NexlineCore) is the RN
  `parseBlocks` port: lines, code, images (`/media/` made absolute, loaded with the token by `NexaClient`),
  media cards, `OPEN:` app links (`AppLauncher`: app scheme, then web; voice mode opens once after the reply
  ends), camera and HA markers. Parity with the RN app is the default (Zé, 27 Oct): its `src/` is the spec.
- UI (27 Oct, build 12+): the RN app's design made native and better: Zé wants it *much better than the RN app*,
  never a plain rebuild, and never to re-test what already works. RN `app/` + `src/components` are the design spec.
  `Theme` (palette, Liquid Glass `glassCard`, `AmbientBackground` = animated MeshGradient in the bot's colour,
  `Avatar`), `HomeView` (agents + Home/Settings), `ChatView` (railed bubbles in `MessageViews`, tool traces, slash
  commands, photo attach, live mode), `VoiceModeView` (`AuraOrb`: Canvas particle halo + bars driven by
  `VoiceLevels` = her queued audio's RMS windows and the mic level; mute, standby, end), `DevicesView` +
  `HomeStore`/`CameraFrame`/`HADeviceCard` (serve.py `/ha/*`), `InlineAudio` (+ `AudioCard`, `NowPlayingBar`:
  serve.py `/youtube/stream` proxy, 503 = warming, lock-screen controls; voice pauses while a mix plays),
  `SettingsView` (per-agent engine/voice with preview, model override, keys), `Intents` (App Shortcut "Talk to
  Nexa"), `Router` (navigation, voice cover, `nexlinevoice://voice|chat|home/<bot>`).
- One `TalkModel` for the whole app (created in `NexlineVoiceApp`): two voice-processing engines would fight. Agents
  are a seam on it (`select(bot)`, `replies()` → `NexaClient.chat` or `AgentClient`, OpenAI SSE with Bearer key +
  `X-Hermes-Session-Id`); `ChatStore` keeps Carapava/Mamadona chats (and a Nexa cache) on the phone. With the
  session header, Hermes reads history from its own state.db and ignores the body's, so a cut-off agent reply is
  marked on the phone and the next turn starts with "[I cut your last reply off; I heard …]". Only Nexa gets
  `/chat/interrupt` (until build 19 every bot's cut-in rewrote Nexa's history). In voice mode the agents get
  `AgentClient.voiceHint` as the system message: the reply is spoken, and `[pause]` is silence. Standby
  (name gate + conversation window), mute and the music hand-off sit around the tested listen/send/speak path,
  which must stay as it is. Standby defaults off.
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
  heard the user above the line, which stops a self-talk loop. Build 25: with Deepgram, a quiet voice also counts
  when the turn's first word began 0.3 s or more after listening began, since her echo comes from earlier. On the
  phone it must still reach max(-55 dB, floor + 8). On a speaker it needs no level, because the floor there rises to her voice.
- Cut-in (build 16): the whole reply uses the playback line, including the silent gaps between pieces, and the
  first 3.5 s of her voice after a start or route change are strict (+8 dB, 400 ms) while echo cancellation
  settles. The first spoken piece is at least 10 characters.
- Cut-in (build 19, `CutInGate`): with Deepgram, a sound over her voice only pauses playback (`pausePlayback`
  keeps the queue). Words with Deepgram word times that end after the pause, or near it and not hers, cut her
  off as of the pause. Sound without words never cuts (build 26: the radio did, three times); after 1.5 s
  paused she carries on and the room counts as noisy. 1 s of quiet with no words and she carries on: the
  timeline, levels, `playbackEnd` and settling all move by the pause, with 1 s strict after. The iPhone
  recognizer has no word times, so it still cuts at once. The log says "sound over her", then "carried on" or
  "cut off by your words".
- Noisy room (build 26): blocks loud ≥25% of the time while she thinks (≥20 blocks), or a pause that ended on
  sound without words, put the reply in words-only cut-in like a speaker. The level trigger is off, two foreign
  words pause and two confirm, and no quiet-voice turns are taken. It is re-measured every reply.
- Speaker mode (build 21): voice processing puts the session in voice-chat mode, which only allows call routes,
  so a music-only speaker (the JBL Tuner, A2DP) was dropped for the iPhone speaker. `start()` notes the
  Bluetooth/AirPlay output before voice processing. If the route lands on the iPhone speaker 0.7 s later, it
  restarts without voice processing. Headphones and cars move to HFP and keep echo cancellation. In speaker mode
  listening starts after her audio plus `outputLatency` + 0.3 s, and losing the speaker restarts voice with echo
  cancellation.
- Speaker cut-in (build 22): loudness can't be used because the mic hears her. Instead, Deepgram words during
  her reply that aren't in it pause her (`CutInGate.isForeign`: not equal, a letter off, or part of one of her
  words; numbers and words under three letters never count). Two such words pause her, because one can be her
  own word misheard. The gate then confirms as on the phone, with `leadIn` 1.5 s and `echoTail` at least 1.5 s:
  the JBL keeps playing after a pause for longer than iOS reports. When she finishes on a speaker, the next turn drops words that are
  hers until `echoTail` after she stopped (her late-recognized words had become the user's turn).
- End of turn (build 23): the Endpointer counts quiet from the newest word's end (Deepgram word times), not from
  result arrival, and ignores empty results. Both had held turns open until Deepgram's `UtteranceEnd`
  (2.7-4.8 s on the JBL). A finalized sentence ending in `.`/`?`/`!` ends the turn after 0.8 s of quiet without
  waiting for `speech_final`.
- Playback format is 24 kHz mono float; xAI streams 24 kHz 16-bit PCM, decoded to float.
- Logs use subsystem `com.nexlineai.voice`; read them on Omarchy with `idevicesyslog` over USB. The app keeps the
  last 500 lines: Settings → Diagnostics → Copy log. A Deepgram turn logs how long after the last word it ended
  and why (`speech_final`, `UtteranceEnd` or the silence backstop).
