import SwiftUI
import WebKit

/// Shape A — wrap the verified gpt-voice web page (served by server/serve.py
/// on the Mac) and let its WebRTC session run inside WKWebView, with the
/// app-level AVAudioSession already set to .voiceChat.
struct VoiceWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(host: url.host ?? "") }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        if #available(iOS 16.4, *) { web.isInspectable = true }  // Safari devtools from the Mac
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url?.host != url.host { web.load(URLRequest(url: url)) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let host: String
        init(host: String) { self.host = host }

        // serve.py uses a self-signed cert for LAN HTTPS (getUserMedia needs a
        // secure origin). WKWebView has no "accept the warning" UI, so trust
        // the configured host explicitly. Demo-only; never ship this pattern.
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               challenge.protectionSpace.host == host,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        // Grant getUserMedia without WebKit's per-origin mic prompt (the app
        // already holds the OS mic permission via NSMicrophoneUsageDescription).
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }

        // WebKit reconfigures the audio session when capture starts — put our
        // .voiceChat mode back once the page is up and again after navigation.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            AudioSessionConfigurator.apply()
        }
    }
}
