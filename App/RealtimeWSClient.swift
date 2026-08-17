import Foundation
import AVFoundation

/// Shape B — fully native fallback for when the WKWebView path still echoes.
/// AVAudioEngine with voice processing enabled on the input node (the same
/// OS echo canceller FaceTime uses), PCM16 24kHz mono streamed to the OpenAI
/// Realtime API over WebSocket, deltas played through the same engine.
///
/// Session config (model, semantic VAD, voice, transcription) is minted
/// server-side by serve.py's /token — the ephemeral secret carries it, so the
/// app only appends audio and reacts to events. The `output_audio_buffer.*`
/// events are WebRTC-only; over WS we know playback state because we are the
/// one playing.
final class RealtimeWSClient: NSObject, ObservableObject, URLSessionDelegate {
    enum State: String { case idle, minting, connecting, listening, speaking }

    struct Line: Identifiable {
        let id = UUID()
        let who: String   // "you" | "ai" | "sys"
        let text: String
    }

    @Published var state: State = .idle
    @Published var lines: [Line] = []

    private var urlSession: URLSession!
    private var ws: URLSessionWebSocketTask?
    private var serverHost = ""
    private var serverURL: URL?
    // Mic health counters, reported to the Mac once a second.
    private var micFrames = 0
    private var micPeak: Float = 0
    private var micReportAt = Date()
    private var seenEventTypes = Set<String>()
    private var heartbeat: Timer?
    private var tapCallbacks = 0
    private var vpEnabled = true

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // The Realtime API's wire format is PCM16 24kHz mono; we play Float32 at
    // the same rate and let the engine resample to the hardware route.
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 24000, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: 24000, channels: 1, interleaved: true)!
    private var micConverter: AVAudioConverter?
    private var assistantSpeaking = false

    // MARK: session lifecycle

    // Synchronous re-entry guard: `state` is published on the main queue, so
    // two immediate onAppear calls both still read .idle and double-start.
    private var startedOnce = false

    func start(serverURL: URL) {
        guard !startedOnce else { return }
        startedOnce = true
        serverHost = serverURL.host ?? ""
        self.serverURL = serverURL
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        setState(.minting)
        remoteLog("start: native mode, server \(serverURL.absoluteString)")
        // Ask for the mic explicitly — without permission the engine runs but
        // captures silence, which looks exactly like "listening, nothing happens".
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self else { return }
            self.remoteLog("mic permission: \(granted ? "granted" : "DENIED")")
            guard granted else {
                self.post("sys", "microphone permission denied — enable in Settings > Privacy > Microphone")
                self.stop()
                return
            }
            self.mintSecret(serverURL: serverURL) { result in
                switch result {
                case .failure(let err):
                    self.post("sys", "token error: \(err.localizedDescription)")
                    self.stop()
                case .success(let secret):
                    self.remoteLog("token minted ok")
                    self.connect(secret: secret)
                }
            }
        }
    }

    func stop() {
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
        }
        assistantSpeaking = false
        DispatchQueue.main.async { self.heartbeat?.invalidate(); self.heartbeat = nil }
        setState(.idle)
    }

    // MARK: token mint (serve.py /token, self-signed LAN cert)

    private func mintSecret(serverURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: serverURL.appendingPathComponent("token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // tools: [] — serve.py defaults to flip_coin, and a tool nobody
        // answers would stall the model mid-conversation.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["tools": []])
        urlSession.dataTask(with: req) { data, _, error in
            if let error { return completion(.failure(error)) }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let secret = obj["value"] as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no data"
                return completion(.failure(NSError(domain: "mint", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(body.prefix(300))])))
            }
            completion(.success(secret))
        }.resume()
    }

    // Accept serve.py's self-signed cert for the configured Mac host only.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == serverHost,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: WebSocket to OpenAI

    private func connect(secret: String) {
        setState(.connecting)
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!)
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: req)
        ws = task
        task.resume()
        receiveLoop()
        do {
            try startAudio()
            setState(.listening)
        } catch {
            post("sys", "audio engine failed: \(error.localizedDescription)")
            stop()
        }
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                if self.state != .idle {
                    self.post("sys", "socket closed: \(err.localizedDescription)")
                    DispatchQueue.main.async { self.stop() }
                }
            case .success(let msg):
                if case .string(let text) = msg, let data = text.data(using: .utf8),
                   let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handleEvent(ev)
                }
                self.receiveLoop()
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let ws, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    private func handleEvent(_ ev: [String: Any]) {
        if let t = ev["type"] as? String, seenEventTypes.insert(t).inserted {
            remoteLog("first event: \(t)")
        }
        switch ev["type"] as? String {
        case "response.output_audio.delta":
            if let b64 = ev["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                assistantSpeaking = true
                setState(.speaking)
                schedulePlayback(pcm)
            }
        case "input_audio_buffer.speech_started":
            // Barge-in: flush local playback and cancel the in-flight response.
            if assistantSpeaking {
                assistantSpeaking = false
                DispatchQueue.main.async { self.player.stop(); self.player.play() }
                send(["type": "response.cancel"])
            }
            setState(.listening)
        case "response.done":
            assistantSpeaking = false
            setState(.listening)
        case "conversation.item.input_audio_transcription.completed":
            post("you", ev["transcript"] as? String ?? "")
        case "response.output_audio_transcript.done":
            post("ai", ev["transcript"] as? String ?? "")
        case "error":
            post("sys", "error: \(ev["error"].map { "\($0)" } ?? "?")")
        default:
            break
        }
    }

    // MARK: audio

    private func startAudio() throws {
        // NO AVAudioEngine-level voice processing: on this iPhone 17 Pro the
        // VP unit either never delivers an input callback (engine runs, tap
        // dead, mic silent) or crashes engine setup with an NSException Swift
        // cannot catch. The echo cancellation under test comes from the
        // AVAudioSession .voiceChat mode (the same OS AEC WebKit rides), so
        // the plain engine is both stable and still the right experiment.
        try startAudio(vp: false)
    }

    private func startAudio(vp: Bool) throws {
        AudioSessionConfigurator.apply()
        let input = engine.inputNode
        // FaceTime's echo canceller — set before the engine starts, on BOTH
        // IO nodes per Apple's docs.
        try input.setVoiceProcessingEnabled(vp)
        try engine.outputNode.setVoiceProcessingEnabled(vp)
        vpEnabled = vp

        let route = AVAudioSession.sharedInstance().currentRoute
        let ins = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        remoteLog("route: in [\(ins)] out [\(outs)]")

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let micFormat = input.outputFormat(forBus: 0)
        micConverter = AVAudioConverter(from: micFormat, to: sendFormat)
        input.installTap(onBus: 0, bufferSize: 2400, format: micFormat) { [weak self] buffer, _ in
            self?.pumpMic(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        remoteLog("engine started vp=\(vp), mic format \(micFormat.sampleRate)Hz x\(micFormat.channelCount)")

        // Heartbeat even when the tap goes silent — pumpMic can't report a
        // tap that never fires.
        DispatchQueue.main.async {
            self.heartbeat?.invalidate()
            self.heartbeat = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.remoteLog(String(format: "hb: state %@, vp %d, taps %d, mic %d frames since last, peak %.3f",
                                      self.state.rawValue, self.vpEnabled ? 1 : 0, self.tapCallbacks, self.micFrames, self.micPeak))
                self.micFrames = 0; self.micPeak = 0
            }
        }
    }

    private func pumpMic(_ buffer: AVAudioPCMBuffer) {
        tapCallbacks += 1
        guard let converter = micConverter, ws != nil else { return }
        let ratio = sendFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])

        // Once-a-second mic health line to the Mac: frame count proves the tap
        // fires, peak proves real audio (all-zero peak = silent capture).
        micFrames += Int(out.frameLength)
        for i in 0..<Int(out.frameLength) {
            micPeak = max(micPeak, abs(Float(ch[0][i]) / 32768.0))
        }
    }

    private func schedulePlayback(_ pcm: Data) {
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16 = raw.bindMemory(to: Int16.self)
            let out = buf.floatChannelData![0]
            for i in 0..<frames { out[i] = Float(int16[i]) / 32768.0 }
        }
        DispatchQueue.main.async {
            guard self.engine.isRunning else { return }
            self.player.scheduleBuffer(buf)
            if !self.player.isPlaying { self.player.play() }
        }
    }

    // MARK: helpers

    private func setState(_ s: State) {
        DispatchQueue.main.async { if self.state != s || s == .idle { self.state = s } }
    }

    private func post(_ who: String, _ text: String) {
        guard !text.isEmpty else { return }
        remoteLog("[\(who)] \(text)")
        DispatchQueue.main.async {
            self.lines.append(Line(who: who, text: text))
            if self.lines.count > 200 { self.lines.removeFirst(self.lines.count - 200) }
        }
    }

    /// Fire-and-forget diagnostics to serve.py's /log — the Mac's terminal is
    /// the debugger, the human never reads the phone screen.
    private func remoteLog(_ msg: String) {
        guard let serverURL else { return }
        var req = URLRequest(url: serverURL.appendingPathComponent("log"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["msg": msg])
        urlSession.dataTask(with: req).resume()
    }
}
