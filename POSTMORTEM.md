# Postmortem — 2026-08-16 debugging session (failure)

The app was handed to the user broken **four separate times**. The session was
stopped by the user before the app ever worked. This file is the honest record.

## What was wrong with how I worked (the actual failure)

1. **Shipped untested builds to a human and used him as the test harness.**
   Each iteration cost the user an unlock/tap/report cycle he explicitly did
   not want. The remote-verification loop (devicectl launch + `/log`
   diagnostics) should have been built FIRST, not after three failures.
2. **Fixed one suspected cause at a time** instead of shipping all suspects in
   one build.
3. **Missed evidence already in hand.** The "URL box is empty" report proved a
   stored-empty-value was shadowing the baked default; I shipped another build
   without connecting that dot.
4. **Asked the user for an API key that was on disk** (`~/clawd/clawd-md/.env.clawd`)
   despite standing instructions.

## Bug-by-bug record

| # | Symptom (user-visible) | Root cause | Status |
|---|---|---|---|
| 1 | App pointed at `.61`, dead | Stale build-machine IP baked in as default | fixed |
| 2 | Mode A blank page, mode B "token error" | Missing `NSLocalNetworkUsageDescription` — iOS silently blocks app→LAN; phone-Safari worked (exempt), which masked it | fixed |
| 3 | URL box empty | Leftover stored `""` from an interim build shadows the `@AppStorage` default | fixed (seeded in `init`) |
| 4 | "LISTENING", nothing happens | Mic captures nothing — see open bug | **OPEN** |

## The open bug (where it died)

Native mode connects fully (token minted, `session.created` received, engine
reports started, route = built-in mic + speaker) but the **input tap delivers
zero callbacks** — no audio ever reaches the API. Later builds crash during
engine setup: device log always ends right after the `route:` line, and
AVFoundation setup failures are NSExceptions that Swift `try` cannot catch, so
there is no in-app error line. Observed on iPhone 17 Pro, iOS with Xcode 26.6
SDK. Tried: voice processing input-only (one 2040-frame burst, then dead),
VP on both IO nodes (engine starts, tap never fires), no VP at all (still dies
after `route:`). NOT yet ruled out: the `player`/`mainMixerNode` connect at
24kHz Float32 throwing on this hardware; something in `AVAudioSession`
`.voiceChat` + `.defaultToSpeaker` interacting with the engine graph.

**Next diagnostic step (one command, no user interaction):** with the phone
unlocked, run a console-attached launch and read the uncaught-exception text:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun devicectl device process launch --console --terminate-existing \
  --device 8B053FBC-B638-548F-B045-F5DDE25D3BDD com.example.reactapp
```

## What IS verified working

- **Protocol end-to-end**: `server/../scratchpad ws_probe` replay (mint token
  from serve.py → wss realtime → stream spoken PCM → got "2 plus 2 is 4"
  back). Server, session config, event names, and the app's exact WS flow are
  all correct.
- Build/sign/install pipeline without an Xcode account: build unsigned, embed
  the Xcode-managed `com.example.reactapp` profile, `codesign` with the
  existing dev cert, install + launch via `devicectl`.
- Remote diagnostics: the app streams every internal event and 2s mic-level
  heartbeats to serve.py `/log` (`server/device.log`), so no human ever needs
  to read the phone screen again.
- Mode A (WKWebView) reaches the page; its echo behavior is untested in-app
  (the user's echo-loop report was phone Safari, which has no `.voiceChat`).

## State at stop

- Everything committed and pushed through `23c015e` (installed build = same).
- Token server killed; all watchers/loops killed; nothing touches the phone.
