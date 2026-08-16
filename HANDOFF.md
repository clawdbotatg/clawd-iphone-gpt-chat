# Handoff — build & test on a machine that has Xcode

Everything is committed. The app has never been compiled (no Xcode on the
machine that wrote it), so expect possible small compile fixes, most likely in
`App/RealtimeWSClient.swift` (the native mode, ~350 lines). Mode A (webview)
is small and low-risk.

## 1. On the new Mac — start the token server

```sh
git clone https://github.com/clawdbotatg/clawd-iphone-gpt-chat.git
cd clawd-iphone-gpt-chat/server
echo 'OPENAI_API_KEY=sk-...' > .env    # serve.py reads .env; file is gitignored
python3 serve.py
```

It prints two URLs. The one you want is `https://<lan-ip>:8444`.
(Don't use `run-server.sh` — that pulls the key from clawd's credential
store, which only exists on clawd's Mac.)

Quick check: `curl -sk -X POST https://127.0.0.1:8444/token | grep -o value`
→ prints `value`.

## 2. Build the app

1. Open `GPTVoice.xcodeproj` in Xcode.
2. Signing & Capabilities → set your team (personal team is fine).
3. Run on a **real iPhone** — not the simulator; the echo test needs the real
   speaker/mic path. Trust the developer cert on the phone if asked
   (Settings → General → VPN & Device Management).

If you change `project.yml`, regenerate with `xcodegen generate`.

## 3. Run the demo

Phone and Mac on the same wifi.

1. App opens on a setup screen. Put the new Mac's URL in the field
   (`https://<lan-ip>:8444` — the baked-in default is the old machine, just
   overtype it).
2. Mode **A · WebView**, hit Start, then Start again on the web page itself.
3. Talk to it.

## 4. The speaker loop test (the actual deliverable)

Built-in speaker, normal volume, NO headphones:

1. "Explain how sourdough works in detail" — stay silent. PASS = it finishes;
   FAIL = it reacts to its own voice.
2. Interrupt it mid-answer by voice. PASS = stops within ~1s.
3. Trail off with "umm…" mid-sentence. PASS = it waits.
4. Ten-turn conversation. PASS = zero self-triggered turns.

If A fails 1 or 4 (echo): flip to mode **B · Native** on the setup screen and
rerun all four.

## 5. Record results

Put per-step PASS/FAIL and which shape (A or B) in the Status block of
`docs/voice/BUILD-IOS-APP.md` in **clawd-harness**, and push.
