# Nexline Voice for iPhone

Native iPhone client for the Nexline voice agents (Nexa, Mamadona, Cara Pava). It replaces the Expo /
React Native app `nexline-voice-app`.

**Status:** audio spike. One screen that proves echo cancellation and barge-in on the phone, with no
network and no keys. The voice loop (speech-to-text, agents, text-to-speech) comes next.

## Build

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and never committed.

```bash
xcodegen generate
swift test --package-path Packages/NexlineKit     # pure-Swift logic
scripts/ci-build-unsigned.sh                       # unsigned device IPA
```

CI (GitHub Actions, `macos-26`):
- `build.yml` runs on every push to `main`: package tests plus an unsigned IPA as an artifact. No secrets.
- `testflight.yml` runs on `v*` tags in the approval-gated `testflight` environment and uploads a signed
  build to TestFlight (internal testers only).

No API keys are compiled into the app. They are entered on the phone and kept in the Keychain.

## Layout

- `App/`: the SwiftUI app.
- `Packages/NexlineKit/`:
  - `NexlineCore`: pure Swift (levels, barge-in detection) with tests.
  - `NexlineAudio`: the AVAudioEngine voice engine (iOS only).
- `scripts/`: CI scripts.

## Licence

Source available, all rights reserved. See `LICENSE`.
