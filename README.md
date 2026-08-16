# clawd-iphone-gpt-chat

Demo 1 of the clawd-harness voice series (`docs/voice/BUILD-IOS-APP.md`): the
smallest possible iPhone app you can talk to — OpenAI `gpt-realtime` (semantic
VAD, barge-in) with **iOS OS-level echo cancellation** via
`AVAudioSession.Mode.voiceChat`, the setting browsers can't reach. The whole
product is ten minutes of natural conversation on the iPhone's built-in
speaker without the model hearing itself.

Both build shapes from the spec ship in one app, behind a segmented control:

- **A · WebView** (primary bet): a WKWebView wrapping the verified
  [gpt-voice](https://github.com/clawdbotatg/gpt-voice) WebRTC page (vendored
  in `server/`), with the app's audio session pre-set to
  `.playAndRecord`/`.voiceChat`/`.defaultToSpeaker` and re-asserted whenever
  WebKit touches it. Tests the bet that OS AEC covers WebKit's WebRTC audio.
- **B · Native** (fallback if A echoes): no webview — `AVAudioEngine` with
  `setVoiceProcessingEnabled(true)`, PCM16 24kHz mono over WebSocket
  (`input_audio_buffer.append` / `response.output_audio.delta`), barge-in by
  flushing playback + `response.cancel` on `input_audio_buffer.speech_started`.

The real `OPENAI_API_KEY` never leaves the Mac: `server/serve.py` mints
ephemeral client secrets (`/token`), and serves the web page over self-signed
HTTPS on the LAN (getUserMedia needs a secure origin). Both app modes trust
that one self-signed host explicitly.

## Run it

**On the Mac** (this repo, `server/`):

```sh
server/run-server.sh     # pulls the key from the local credential store
                         # → https://<mac-lan-ip>:8444
```

(Ports are 8124/8444 — shifted +1 from upstream gpt-voice so both can run on
one Mac.)

**On the iPhone:**

1. Open `GPTVoice.xcodeproj` in Xcode (or regenerate with `xcodegen generate`).
2. Signing & Capabilities → pick your team (personal team is fine, no paid
   account needed for a dev build).
3. Run on a real iPhone (not the simulator — the echo test needs the real
   speaker/mic path). Trust the developer cert on the phone if prompted.
4. In the app: check the server URL (defaults to this Mac's LAN IP :8444),
   pick mode A, hit Start, then Start on the page itself.

## The acceptance test

The speaker loop test from `docs/voice/README.md` in clawd-harness — built-in
speaker, normal volume, no headphones:

1. Long answer, stay silent → it must finish without reacting to its own voice.
2. Interrupt it by voice → it stops within ~1s.
3. Trail off with "umm…" → it waits (semantic VAD).
4. Ten turns → zero self-triggered turns.

If mode A fails step 1/4 (echo), switch to mode B and rerun. Record results
in `docs/voice/BUILD-IOS-APP.md`'s Status block.
