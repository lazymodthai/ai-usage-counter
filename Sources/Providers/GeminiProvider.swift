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
            function normalizePct(value, text) {
                const pct = parseFloat(value);
                return /left|remain/i.test(text) ? Math.max(0, 100 - pct) : pct;
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
            function titleCaseLabel(s) {
                return s
                    .replace(/\\s+/g, ' ')
                    .replace(/^(gemini\\s*)+/i, 'Gemini ')
                    .trim();
            }
            function quotaLanes(text) {
                const lines = text.split('\\n').map(s => s.trim()).filter(Boolean);
                const lanes = [];
                let group = null;
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i];
                    if (/^(Gemini Flash|Gemini Pro|Claude|OpenAI|GPT)$/i.test(line)
                        && !/(\\d+(?:\\.\\d+)?)\\s*%/.test(line)
                        && line.length < 80) {
                        group = titleCaseLabel(line);
                        continue;
                    }

                    const window = lines.slice(i, i + 4).join(' ');
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
                        reset: reset ? reset[1].trim() : null
                    });
                }
                return lanes;
            }
            function grab() {
                const text = pageText();
                const session = near(text, /5[\\s-]?hour|five[\\s-]?hour|current\\s+limit|current\\s+usage|usage\\s+limit|ขีดจำกัด|การใช้งาน/i);
                const weekly = near(text, /week|weekly|สัปดาห์/i);
                const lanes = quotaLanes(text);
                if (!session && !weekly && lanes.length === 0) return null;
                return { session, weekly, lanes };
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
                if (clickMatch(/settings|setting|usage|quota|limit|การตั้งค่า|การใช้งาน|ขีดจำกัด/i)) {
                    await new Promise(res => setTimeout(res, 1200));
                    if (clickMatch(/usage|quota|limit|การใช้งาน|ขีดจำกัด/i)) {
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
        let urls = [
            "https://gemini.google.com/app",
            "https://gemini.google.com/app/settings",
            "https://gemini.google.com/app/settings/usage",
            "https://gemini.google.com/app/usage",
        ].compactMap(URL.init(string:))

        for url in urls {
            let result = await fetchFromUsagePage(url, script: script)
            if case .failure = result {
                continue
            }
            return result
        }

        webFetcher.invalidatePage()
        return .failure
    }

    private func fetchFromUsagePage(_ url: URL, script: String) async -> FetchResult {
        guard let raw = await webFetcher.run(
                pageURL: url,
                script: script,
                reloadIfOlderThan: 0,
                settleDelay: 3.0),       // Gemini's SPA is slow to hydrate
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure
        }
        if (obj["error"] as? String) == "auth" { return .authExpired }
        guard let payload = obj["data"] as? [String: Any] else {
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
        let lanes = parseQuotaLanes(payload["lanes"], relativeTo: now)

        guard session.pct != nil || weekly.pct != nil || !lanes.isEmpty else { return .failure }
        var u = ProviderUsage(fetchedAt: now)
        u.sessionPct = session.pct
        u.weeklyPct = weekly.pct
        u.quotaLanes = lanes
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
