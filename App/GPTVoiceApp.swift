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
            // No .allowBluetooth: the deliverable is the BUILT-IN speaker/mic
            // loop test, and a paired BT device (AirPods in a pocket, a car)
            // silently steals the mic route — captured audio is pure silence.
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("audio session config failed: \(error)")
        }
    }
}
