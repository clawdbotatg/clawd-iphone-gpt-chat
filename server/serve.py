#!/usr/bin/env python3
"""Minimal server for the gpt-realtime WebRTC demo.

Serves index.html and mints ephemeral client secrets so the real
OPENAI_API_KEY never reaches the browser. Pure stdlib.

Run:  python3 serve.py   (reads OPENAI_API_KEY from ./.env or the environment)
"""
import json
import os
import socket
import ssl
import subprocess
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent
# Defaults shifted +1 from upstream gpt-voice (8123/8443) so both servers can
# run on the same Mac without colliding.
PORT = int(os.environ.get("DEMO_PORT", "8124"))
TLS_PORT = int(os.environ.get("DEMO_TLS_PORT", "8444"))
MODEL = os.environ.get("REALTIME_MODEL", "gpt-realtime")
CERT_DIR = HERE / ".cert"  # gitignored


def load_env():
    env_file = HERE / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip().strip('"'))


# Allowlists — the browser picks from these; anything else falls back to a default.
MODELS = ["gpt-realtime", "gpt-realtime-mini", "gpt-realtime-2.1"]
VOICES = ["marin", "cedar", "alloy", "echo", "sage", "shimmer", "verse"]
EAGERNESS = ["low", "medium", "high", "auto"]
VAD_TYPES = ["semantic_vad", "server_vad"]

# Tool *definitions* live here (they go into the session config); the
# implementations live client-side in index.html's TOOL_IMPLS.
TOOL_DEFS = {
    "flip_coin": {
        "type": "function", "name": "flip_coin",
        "description": "Flip a coin and return heads or tails.",
        "parameters": {"type": "object", "properties": {}},
    },
    "get_time": {
        "type": "function", "name": "get_time",
        "description": "Get the user's current local date and time.",
        "parameters": {"type": "object", "properties": {}},
    },
    "eth_price": {
        "type": "function", "name": "eth_price",
        "description": "Get the current price of Ethereum (ETH) in US dollars.",
        "parameters": {"type": "object", "properties": {}},
    },
}

_SPEAK_CACHE = {}  # voice -> mp3 bytes (previews are identical per voice, so mint once)


def tts_preview(voice):
    """Short sample clip so picking a voice in the dashboard is audible.
    Uses the TTS endpoint (all 7 realtime voices verified present on it,
    2026-08-16) — close enough for a preview, though realtime prosody differs."""
    if voice not in VOICES:
        return 400, {"error": "unknown voice"}, "application/json"
    if voice in _SPEAK_CACHE:
        return 200, _SPEAK_CACHE[voice], "audio/mpeg"
    key = os.environ.get("OPENAI_API_KEY", "")
    if not key or key == "XXX":
        return 500, {"error": "OPENAI_API_KEY missing"}, "application/json"
    body = json.dumps({
        "model": "gpt-4o-mini-tts",
        "voice": voice,
        "input": f"Hey there! I'm {voice}. This is what I sound like.",
        "response_format": "mp3",
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            audio = r.read()
        _SPEAK_CACHE[voice] = audio
        return 200, audio, "audio/mpeg"
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:500]}, "application/json"
    except Exception as e:
        return 502, {"error": str(e)}, "application/json"


DEFAULT_INSTRUCTIONS = (
    "You are a friendly, concise voice assistant for a demo. "
    "Keep answers short and conversational."
)


def _pick(val, allowed, default):
    return val if val in allowed else default


def mint_client_secret(cfg):
    key = os.environ.get("OPENAI_API_KEY", "")
    if not key or key == "XXX":
        return 500, {"error": "OPENAI_API_KEY missing — copy .env.example to .env and fill it in"}
    model = _pick(cfg.get("model"), MODELS, MODEL)
    voice = _pick(cfg.get("voice"), VOICES, "marin")
    vad = _pick(cfg.get("vad"), VAD_TYPES, "semantic_vad")
    turn_detection = {"type": vad}
    if vad == "semantic_vad":
        turn_detection["eagerness"] = _pick(cfg.get("eagerness"), EAGERNESS, "auto")
    instructions = str(cfg.get("instructions") or DEFAULT_INSTRUCTIONS)[:4000]
    tools = [TOOL_DEFS[t] for t in cfg.get("tools", ["flip_coin"]) if t in TOOL_DEFS]
    output = {"voice": voice}
    try:
        speed = float(cfg.get("speed", 1.0))
        if 0.25 <= speed <= 1.5 and speed != 1.0:
            output["speed"] = speed
    except (TypeError, ValueError):
        pass
    body = json.dumps({
        "session": {
            "type": "realtime",
            "model": model,
            "instructions": instructions,
            "audio": {
                "input": {
                    "turn_detection": turn_detection,
                    "transcription": {"model": "gpt-4o-mini-transcribe"},
                },
                "output": output,
            },
            "tools": tools,
        }
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/realtime/client_secrets",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return 200, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:2000]}
    except Exception as e:  # network etc.
        return 502, {"error": str(e)}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, data, ctype="application/json"):
        raw = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.split("?")[0] in ("/", "/index.html"):
            self._send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/token":
            try:
                n = int(self.headers.get("Content-Length") or 0)
                cfg = json.loads(self.rfile.read(n)) if n else {}
            except Exception:
                cfg = {}
            code, data = mint_client_secret(cfg if isinstance(cfg, dict) else {})
            self._send(code, data)
        elif self.path == "/speak":
            try:
                n = int(self.headers.get("Content-Length") or 0)
                voice = json.loads(self.rfile.read(n)).get("voice", "")
            except Exception:
                voice = ""
            code, data, ctype = tts_preview(voice)
            self._send(code, data, ctype)
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args))


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return ""


def ensure_cert(ip):
    """Self-signed cert so getUserMedia works over the LAN (http on a LAN IP
    is not a secure context — the browser refuses the mic). Regenerated if the
    LAN IP is no longer in the SAN list."""
    cert, key = CERT_DIR / "cert.pem", CERT_DIR / "key.pem"
    san = f"subjectAltName=DNS:localhost,IP:127.0.0.1" + (f",IP:{ip}" if ip else "")
    stamp = CERT_DIR / "san.txt"
    if not (cert.exists() and key.exists() and stamp.exists() and stamp.read_text() == san):
        CERT_DIR.mkdir(exist_ok=True)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "365",
            "-subj", "/CN=gpt-voice-demo", "-addext", san,
        ], check=True, capture_output=True)
        stamp.write_text(san)
    return cert, key


if __name__ == "__main__":
    load_env()
    ip = lan_ip()
    threading.Thread(
        target=ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever,
        daemon=True,
    ).start()
    print(f"http://127.0.0.1:{PORT}  (model: {MODEL})")
    try:
        cert, key = ensure_cert(ip)
        tls_srv = ThreadingHTTPServer(("0.0.0.0", TLS_PORT), Handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        tls_srv.socket = ctx.wrap_socket(tls_srv.socket, server_side=True)
        if ip:
            print(f"https://{ip}:{TLS_PORT}  (LAN — accept the self-signed cert warning)")
        print(f"https://127.0.0.1:{TLS_PORT}")
        tls_srv.serve_forever()
    except FileNotFoundError:
        print("openssl not found — LAN HTTPS disabled, http://127.0.0.1 only")
        threading.Event().wait()
