import Foundation
import WebKit
import AppKit

// Generic web login window — one per provider, each with its own cookie store.
// Owns the NSWindow/WKWebView and retains them until explicitly closed.
@MainActor
final class WebAuthController: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    struct Config {
        let providerID: ProviderID
        let title: String
        let startURL: URL
        let dataStore: WKWebsiteDataStore
        /// Called after each page load. Return true when the user is signed in;
        /// the window then closes itself (after a short cookie-persist delay).
        let loginCheck: @MainActor (WKWebView, URL) async -> Bool
    }

    private static var active: [ProviderID: WebAuthController] = [:]

    private var window: NSWindow?
    private var webView: WKWebView?
    private let config: Config
    private let onComplete: @MainActor () -> Void
    private var closing = false

    static func show(_ config: Config, onComplete: @escaping @MainActor () -> Void) {
        if let existing = active[config.providerID] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let ctrl = WebAuthController(config: config, onComplete: onComplete)
        active[config.providerID] = ctrl
        ctrl.openWindow()
    }

    private init(config: Config, onComplete: @escaping @MainActor () -> Void) {
        self.config = config
        self.onComplete = onComplete
        super.init()
    }

    private func openWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = config.title
        w.isReleasedWhenClosed = false        // CRITICAL: ARC manages lifetime
        w.delegate = self
        w.center()
        w.level = .floating

        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = config.dataStore
        wkConfig.preferences.javaScriptCanOpenWindowsAutomatically = true

        let wv = WKWebView(frame: w.contentView!.bounds, configuration: wkConfig)
        wv.autoresizingMask = [.width, .height]
        wv.uiDelegate = self
        wv.navigationDelegate = self
        wv.customUserAgent = safariUserAgent
        wv.load(URLRequest(url: config.startURL))

        w.contentView?.addSubview(wv)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
        self.webView = wv
    }

    // Handle window.open() popups (Google SSO uses these) by loading in same view
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit always calls this on the main thread
        MainActor.assumeIsolated {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !self.closing, let wv = self.webView, let url = wv.url else { return }
            if await self.config.loginCheck(wv, url) {
                self.closing = true
                // small delay so cookies are fully persisted
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.window?.close()
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.webView?.navigationDelegate = nil
            self.webView?.uiDelegate = nil
            self.webView = nil
            self.window = nil
            WebAuthController.active[self.config.providerID] = nil
            self.onComplete()
        }
    }
}
