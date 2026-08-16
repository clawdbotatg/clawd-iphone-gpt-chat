import SwiftUI

/// Shape B UI: a state word and the transcript. The session starts on appear
/// (the mode was chosen behind a Start button, so the user gesture already
/// happened) and stops on disappear.
struct NativeVoiceView: View {
    let serverURL: URL
    @StateObject private var client = RealtimeWSClient()

    var body: some View {
        VStack(spacing: 12) {
            Text(stateWord)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(client.state == .speaking ? .green : .primary)
                .padding(.top, 60)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(client.lines) { line in
                            Text("\(line.who): \(line.text)")
                                .font(.footnote.monospaced())
                                .foregroundStyle(color(for: line.who))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: client.lines.count) { _ in
                    if let last = client.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .onAppear { client.start(serverURL: serverURL) }
        .onDisappear { client.stop() }
    }

    private var stateWord: String {
        switch client.state {
        case .idle: return "OFF"
        case .minting, .connecting: return "CONNECTING…"
        case .listening: return "LISTENING"
        case .speaking: return "SPEAKING"
        }
    }

    private func color(for who: String) -> Color {
        switch who {
        case "you": return .blue
        case "ai": return .green
        default: return .secondary
        }
    }
}
