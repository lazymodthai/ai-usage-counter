import Foundation
import WebKit

// Gemini usage via DOM scraping of gemini.google.com's Usage Limits view
// (Settings → Usage Limits, added May 2026: 5-hour window + weekly limit).
// No known JSON API — gemini.google.com uses obfuscated batchexecute RPCs.
// TODO: watch the network tab for a usable RPC and switch to it if one appears.
@MainActor
final class GeminiProvider: UsageProvider {
    let id = ProviderID.gemini
    private let dataStore = ProviderDataStores.store(for: .gemini)
    private lazy var webFetcher = WebViewFetcher(dataStore: dataStore)

    // MARK: - Auth

    func checkAuth() async -> AuthState {
        let signedIn = await dataStore.hasCookie(domain: "google.com") {
            ["SID", "__Secure-1PSID", "SAPISID"].contains($0.name)
        }
        return signedIn ? .signedIn : .signedOut
    }

    func presentLogin(onComplete: @escaping @MainActor () -> Void) {
        let store = dataStore
        WebAuthController.show(WebAuthController.Config(
            providerID: .gemini,
            title: "Sign in to Gemini",
            startURL: URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fapp")!,
            dataStore: dataStore,
            loginCheck: { _, url in
                guard url.host?.contains("gemini.google.com") == true else { return false }
                return await store.hasCookie(domain: "google.com") {
                    ["SID", "__Secure-1PSID", "SAPISID"].contains($0.name)
                }
            }
        ), onComplete: onComplete)
    }

    func signOut() async {
        webFetcher.release()
        await dataStore.wipeAllData()
    }

    func releaseIdleResources() {
        webFetcher.release()
    }

    // MARK: - Fetch

    func fetchUsage() async -> FetchResult {
        // Strategy: read percentages near the "5-hour"/"week" labels from page text.
        // If they're not visible, walk the UI: click Settings, then Usage Limits,
        // and read the dialog. Label-based matching only — class names churn weekly.
        let script = """
        try {
            if (location.host.indexOf('accounts.google.com') >= 0) {
                return JSON.stringify({ error: 'auth' });
            }
            function pageText() {
                return (document.body.innerText || '').replace(/\\u00a0/g, ' ');
            }
            function near(text, re) {
                const idx = text.search(re);
                if (idx < 0) return null;
                const seg = text.slice(idx, idx + 300);
                const m = seg.match(/(\\d+(?:\\.\\d+)?)\\s*%/);
                if (!m) return null;
                const around = seg.slice(Math.max(0, m.index - 40), m.index + 40);
                const out = { pct: parseFloat(m[1]), remaining: /left|remain/i.test(around) };
                const rm = seg.match(/resets?[^\\n.;]{0,80}/i);
                if (rm) out.reset = rm[0];
                return out;
            }
            function grab() {
                const text = pageText();
                const session = near(text, /5[\\s-]?hour|five[\\s-]?hour/i);
                const weekly = near(text, /week/i);
                if (!session && !weekly) return null;
                return { session, weekly };
            }
            function clickMatch(re) {
                const els = Array.from(document.querySelectorAll(
                    'button, [role=\"button\"], [role=\"menuitem\"], [role=\"tab\"], a'));
                const el = els.find(e => {
                    const label = e.getAttribute('aria-label') || '';
                    const txt = (e.textContent || '').trim();
                    return re.test(label) || (txt.length > 0 && txt.length < 40 && re.test(txt));
                });
                if (el) { el.click(); return true; }
                return false;
            }
            let r = grab();
            if (!r) {
                if (clickMatch(/settings/i)) {
                    await new Promise(res => setTimeout(res, 1200));
                    if (clickMatch(/usage/i)) {
                        for (let i = 0; i < 5 && !r; i++) {
                            await new Promise(res => setTimeout(res, 1000));
                            r = grab();
                        }
                    }
                    // close any dialog we opened so the page stays clean
                    document.dispatchEvent(new KeyboardEvent('keydown',
                        { key: 'Escape', keyCode: 27, bubbles: true }));
                }
            }
            return JSON.stringify(r ? { data: r } : { error: 'notfound' });
        } catch (e) {
            return JSON.stringify({ error: String(e) });
        }
        """
        guard let raw = await webFetcher.run(
                pageURL: URL(string: "https://gemini.google.com/app")!,
                script: script,
                settleDelay: 3.0),       // Gemini's SPA is slow to hydrate
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            webFetcher.invalidatePage()
            return .failure
        }
        if (obj["error"] as? String) == "auth" { return .authExpired }
        guard let payload = obj["data"] as? [String: Any] else {
            webFetcher.invalidatePage()
            return .failure
        }

        let now = Date()
        func parseLane(_ any: Any?) -> (pct: Double?, resetText: String?) {
            guard let d = any as? [String: Any], let pct = providerNum(d["pct"]) else { return (nil, nil) }
            let remaining = (d["remaining"] as? Bool) ?? false
            return (remaining ? max(0, 100 - pct) : pct, d["reset"] as? String)
        }
        let session = parseLane(payload["session"])
        let weekly = parseLane(payload["weekly"])

        guard session.pct != nil || weekly.pct != nil else { return .failure }
        var u = ProviderUsage(fetchedAt: now)
        u.sessionPct = session.pct
        u.weeklyPct = weekly.pct
        if let t = session.resetText {
            u.sessionResetAt = ResetTimeParser.parseSessionReset(t, relativeTo: now)
                ?? ResetTimeParser.parseWeeklyReset(t, relativeTo: now)
        }
        if let t = weekly.resetText {
            u.weeklyResetAt = ResetTimeParser.parseWeeklyReset(t, relativeTo: now)
                ?? ResetTimeParser.parseSessionReset(t, relativeTo: now)
        }
        return .success(u)
    }
}
