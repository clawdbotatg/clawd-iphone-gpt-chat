import SwiftUI
import AVFoundation

@main
struct GPTVoiceApp: App {
    init() { AudioSessionConfigurator.activate() }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// The whole reason this app exists: `.voiceChat` mode routes audio through
/// iOS's OS-level echo canceller (the one the ChatGPT app uses, unreachable
/// from a browser). Configured once at launch and re-asserted on every route
/// change, because WebKit likes to reconfigure the session when getUserMedia
/// starts inside the WKWebView.
enum AudioSessionConfigurator {
    static func activate() {
        apply()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { _ in apply() }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { _ in apply() }
    }

    static func apply() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("audio session config failed: \(error)")
        }
    }
}
