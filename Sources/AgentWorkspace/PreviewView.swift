import SwiftUI
import WebKit

struct PreviewView: NSViewRepresentable {
    let fileURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let fileURL, webView.url != fileURL else { return }
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
    }
}
