import SwiftUI

struct ContentView: View {
    // Prefilled with the token-server Mac's LAN IP at build time so the phone
    // needs zero typing. Editable on the setup screen if the IP moves.
    @AppStorage("serverURL") private var serverURL = "https://192.168.68.60:8444"
    @AppStorage("voiceMode") private var voiceMode = "web"
    @State private var started = false

    private var url: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        if started, let url {
            ZStack(alignment: .topTrailing) {
                if voiceMode == "web" {
                    VoiceWebView(url: url).ignoresSafeArea()
                } else {
                    NativeVoiceView(serverURL: url)
                }
                Button {
                    started = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        } else {
            setupForm
        }
    }

    private var setupForm: some View {
        VStack(spacing: 24) {
            Text("🎙️ gpt-voice").font(.largeTitle.bold())
            Text("Talk to gpt-realtime on the phone speaker.\nEcho cancellation: AVAudioSession .voiceChat")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                Text("Token server on the Mac").font(.caption).foregroundStyle(.secondary)
                TextField("https://<mac-lan-ip>:8444", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Picker("Mode", selection: $voiceMode) {
                Text("A · WebView (WebRTC)").tag("web")
                Text("B · Native (WebSocket)").tag("native")
            }
            .pickerStyle(.segmented)

            Text(voiceMode == "web"
                 ? "Wraps the verified gpt-voice web page; bets that the OS AEC covers WebKit's WebRTC audio."
                 : "Fallback if A echoes: AVAudioEngine voice processing + raw PCM over WebSocket.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                started = true
            } label: {
                Text("Start").font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(url == nil)
        }
        .padding(32)
    }
}
