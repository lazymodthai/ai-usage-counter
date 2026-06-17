import Foundation
import WebKit

// Hidden WKWebView used to run JS inside a provider's logged-in web context.
// Two modes, both via callAsyncJavaScript:
//  - fetch-json: call the site's internal API with the page's cookies/session
//  - scrape-dom: read values out of the rendered page
// The webview is kept alive between fetches (page loads once, scripts re-run),
// and released by the owner when the provider is idle.
@MainActor
final class WebViewFetcher: NSObject, WKNavigationDelegate {
    private let dataStore: WKWebsiteDataStore
    private var webView: WKWebView?
    private var pageLoaded = false
    private var loadFailed = false
    private var lastLoadAt: Date?
    private var currentURL: URL?

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        super.init()
    }

    /// Ensure `pageURL` is loaded (reusing the existing webview when fresh),
    /// then run `script` as an async JS function body and return its result.
    /// The script should `return` a JSON string.
    func run(pageURL: URL,
             script: String,
             reloadIfOlderThan: TimeInterval = 600,
             loadTimeout: TimeInterval = 30,
             settleDelay: TimeInterval = 1.5) async -> String? {
        let needsLoad: Bool
        if webView == nil {
            createWebView()
            needsLoad = true
        } else if currentURL?.absoluteString != pageURL.absoluteString
                    || loadFailed
                    || (lastLoadAt.map { Date().timeIntervalSince($0) > reloadIfOlderThan } ?? true) {
            needsLoad = true
        } else {
            needsLoad = false
        }

        guard let wv = webView else { return nil }

        if needsLoad {
            pageLoaded = false
            loadFailed = false
            currentURL = pageURL
            wv.load(URLRequest(url: pageURL))

            let deadline = Date().addingTimeInterval(loadTimeout)
            while !pageLoaded && !loadFailed && Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard pageLoaded else {
                loadFailed = true
                return nil
            }
            lastLoadAt = Date()
            // Let SPA hydration settle before poking at it
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }

        do {
            let result = try await wv.callAsyncJavaScript(
                script, arguments: [:], in: nil, contentWorld: .defaultClient)
            return result as? String
        } catch {
            return nil
        }
    }

    /// Force the next run() to reload the page (e.g. after an error response).
    func invalidatePage() {
        lastLoadAt = nil
    }

    func release() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        pageLoaded = false
        lastLoadAt = nil
        currentURL = nil
    }

    var isAlive: Bool { webView != nil }

    private func createWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 900), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = safariUserAgent
        webView = wv
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.pageLoaded = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadFailed = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadFailed = true }
    }
}
