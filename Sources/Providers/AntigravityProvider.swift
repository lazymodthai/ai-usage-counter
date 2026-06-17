import Foundation
import WebKit

// Antigravity quota via the Antigravity web surface. It intentionally shares
// Gemini's WKWebsiteDataStore, so one Google login unlocks both providers.
@MainActor
final class AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity
    private let dataStore = ProviderDataStores.store(for: .antigravity)
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
            providerID: .antigravity,
            title: "Sign in to Antigravity",
            startURL: URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fantigravity.google%2F")!,
            dataStore: dataStore,
            loginCheck: { _, url in
                guard url.host?.contains("antigravity.google") == true else { return false }
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
        let script = """
        try {
            if (location.host.indexOf('accounts.google.com') >= 0) {
                return JSON.stringify({ error: 'auth' });
            }
            function pageText() {
                return (document.body.innerText || '').replace(/\\u00a0/g, ' ');
            }
            function normalizePct(value, text) {
                const pct = parseFloat(value);
                return /left|remain/i.test(text) ? Math.max(0, 100 - pct) : pct;
            }
            function titleCaseLabel(s) {
                return s.replace(/\\s+/g, ' ').trim();
            }
            function cleanReset(s) {
                if (!s) return null;
                return s
                    .replace(/^\\s*(?:->|resets?\\s*(?:in|at)?|reset\\s*(?:in|at)?)\\s*/i, '')
                    .replace(/\\s+/g, ' ')
                    .trim();
            }
            function quotaLanes(text) {
                const lines = text.split('\\n').map(s => s.trim()).filter(Boolean);
                const lanes = [];
                let group = null;
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i];
                    if (/^(Gemini Flash|Gemini Pro|Claude|OpenAI|GPT|Antigravity)$/i.test(line)
                        && !/(\\d+(?:\\.\\d+)?)\\s*%/.test(line)
                        && line.length < 80) {
                        group = titleCaseLabel(line);
                        continue;
                    }

                    const window = lines.slice(i, i + 5).join(' ');
                    const pct = window.match(/(\\d+(?:\\.\\d+)?)\\s*%/);
                    if (!pct) continue;

                    const model = line.match(/((?:Gemini|Claude|GPT|OpenAI)[A-Za-z0-9 ._-]*(?:\\([^)]*\\))?)/i)
                        || window.match(/((?:Gemini|Claude|GPT|OpenAI)[A-Za-z0-9 ._-]*(?:\\([^)]*\\))?)/i);
                    if (!model) continue;

                    const label = titleCaseLabel(model[1]);
                    if (lanes.some(l => l.label.toLowerCase() === label.toLowerCase())) continue;

                    const reset = window.match(/(?:->|resets?\\s*(?:in|at)?|reset\\s*(?:in|at)?)\\s*([^|\\n]{1,80})/i);
                    lanes.push({
                        id: label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''),
                        label,
                        group,
                        pct: normalizePct(pct[1], window),
                        reset: cleanReset(reset ? reset[1] : null)
                    });
                }
                return lanes;
            }
            function clickMatch(re) {
                const els = Array.from(document.querySelectorAll(
                    'button, [role=\"button\"], [role=\"menuitem\"], [role=\"tab\"], a'));
                const el = els.find(e => {
                    const label = e.getAttribute('aria-label') || '';
                    const txt = (e.textContent || '').trim();
                    return re.test(label) || (txt.length > 0 && txt.length < 50 && re.test(txt));
                });
                if (el) { el.click(); return true; }
                return false;
            }

            let lanes = quotaLanes(pageText());
            if (lanes.length === 0) {
                clickMatch(/quota|usage|limit|rate/i);
                for (let i = 0; i < 6 && lanes.length === 0; i++) {
                    await new Promise(res => setTimeout(res, 1000));
                    lanes = quotaLanes(pageText());
                }
            }

            return JSON.stringify(lanes.length > 0 ? { data: { lanes } } : { error: 'notfound' });
        } catch (e) {
            return JSON.stringify({ error: String(e) });
        }
        """
        guard let raw = await webFetcher.run(
                pageURL: URL(string: "https://antigravity.google/")!,
                script: script,
                reloadIfOlderThan: 0,
                settleDelay: 3.0),
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

        let lanes = parseQuotaLanes(payload["lanes"], relativeTo: Date())
        guard !lanes.isEmpty else { return .failure }
        var usage = ProviderUsage(fetchedAt: Date())
        usage.quotaLanes = lanes
        return .success(usage)
    }

    private func parseQuotaLanes(_ any: Any?, relativeTo now: Date) -> [ProviderQuotaLane] {
        guard let rows = any as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard
                let id = row["id"] as? String,
                let label = row["label"] as? String,
                let pct = providerNum(row["pct"])
            else { return nil }
            let resetText = row["reset"] as? String
            return ProviderQuotaLane(
                id: id,
                label: label,
                group: row["group"] as? String,
                pct: min(max(pct, 0), 100),
                resetAt: resetText.flatMap {
                    ResetTimeParser.parseSessionReset($0, relativeTo: now)
                        ?? ResetTimeParser.parseWeeklyReset($0, relativeTo: now)
                },
                resetText: resetText
            )
        }
    }
}
