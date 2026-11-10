import Foundation
import WebKit
import os

private let claudeLog = Logger(subsystem: "com.lazymodthai.claude-usage-counter", category: "claude")

// Claude usage via the internal claude.ai JSON API:
//   GET /api/organizations               -> org uuid (cached 24h, prefers lastActiveOrg cookie)
//   GET /api/organizations/{id}/usage    -> { five_hour: {utilization, resets_at},
//                                            seven_day: {utilization, resets_at},
//                                            limits: [{ kind: "weekly_scoped", percent,
//                                                       resets_at, scope.model.display_name }] }
// Primary path is plain URLSession with cookies from the default WKWebsiteDataStore.
// If that's blocked (e.g. Cloudflare), falls back to fetch() inside a hidden WebView.
@MainActor
final class ClaudeProvider: UsageProvider {
    let id = ProviderID.claude
    private let dataStore = ProviderDataStores.store(for: .claude)
    private lazy var webFetcher = WebViewFetcher(dataStore: dataStore)

    private static let orgIDKey = "claudeOrgID"
    private static let orgIDDateKey = "claudeOrgIDFetchedAt"
    private static let planKey = "claudePlanName"

    // MARK: - Auth

    func checkAuth() async -> AuthState {
        let signedIn = await dataStore.hasCookie(domain: "claude.ai") { $0.name == "sessionKey" }
        return signedIn ? .signedIn : .signedOut
    }

    func presentLogin(onComplete: @escaping @MainActor () -> Void) {
        WebAuthController.show(WebAuthController.Config(
            providerID: .claude,
            title: "Sign in to Claude",
            startURL: URL(string: "https://claude.ai/login")!,
            dataStore: dataStore,
            loginCheck: { _, url in
                let s = url.absoluteString
                return s.hasPrefix("https://claude.ai/") && !s.contains("/login") && !s.contains("/auth")
            }
        ), onComplete: onComplete)
    }

    func signOut() async {
        await dataStore.clearCookies(domain: "claude.ai")
        let ud = UserDefaults.standard
        ud.removeObject(forKey: Self.orgIDKey)
        ud.removeObject(forKey: Self.orgIDDateKey)
        ud.removeObject(forKey: Self.planKey)
        webFetcher.release()
    }

    // MARK: - Fetch

    func fetchUsage() async -> FetchResult {
        let cookies = await dataStore.cookies(matching: "claude.ai")
        guard cookies.contains(where: { $0.name == "sessionKey" && !$0.value.isEmpty }) else {
            return .authExpired
        }

        switch await fetchViaURLSession(cookies: cookies) {
        case .success(let u): return .success(u)
        case .authExpired:    return .authExpired
        case .failure:
            claudeLog.notice("URLSession path failed; falling back to WebView")
            return await fetchViaWebView()
        }
    }

    func releaseIdleResources() {
        webFetcher.release()
    }

    private func fetchViaURLSession(cookies: [HTTPCookie]) async -> FetchResult {
        do {
            guard let orgID = try await resolveOrgID(cookies: cookies) else { return .failure }
            let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!
            let (json, status) = try await CookieAPIFetcher.getJSON(
                url: url, cookies: cookies, referer: "https://claude.ai/settings/usage")
            if status == 401 { return .authExpired }
            let keys = ((json as? [String: Any]).map { $0.filter { !($0.value is NSNull) }.keys.sorted() } ?? [])
            claudeLog.debug("usage via URLSession status=\(status) nonNullKeys=\(keys.joined(separator: ","), privacy: .public)")
            guard status == 200, let obj = json as? [String: Any] else { return .failure }
            guard var usage = Self.parseUsage(obj) else { return .failure }
            usage.planName = UserDefaults.standard.string(forKey: Self.planKey)
            return .success(usage)
        } catch {
            return .failure
        }
    }

    /// Org uuid for the usage endpoint. The org list (and the plan derived from it)
    /// is refetched at most once a day; the lastActiveOrg cookie wins for the id.
    private func resolveOrgID(cookies: [HTTPCookie]) async throws -> String? {
        let ud = UserDefaults.standard
        let cookieOrg = cookies.first(where: { $0.name == "lastActiveOrg" && !$0.value.isEmpty })?.value
        let fresh = Date().timeIntervalSince(ud.object(forKey: Self.orgIDDateKey) as? Date ?? .distantPast) < 24 * 3600
        if fresh, let cached = ud.string(forKey: Self.orgIDKey), ud.string(forKey: Self.planKey) != nil {
            return cookieOrg ?? cached
        }
        let (json, status) = try await CookieAPIFetcher.getJSON(
            url: URL(string: "https://claude.ai/api/organizations")!,
            cookies: cookies, referer: "https://claude.ai/")
        claudeLog.notice("organizations status=\(status) type=\(String(describing: type(of: json)), privacy: .public) count=\((json as? [Any])?.count ?? -1)")
        guard status == 200, let orgs = json as? [[String: Any]], !orgs.isEmpty else {
            return cookieOrg ?? ud.string(forKey: Self.orgIDKey)
        }
        let preferred = orgs.first { ($0["uuid"] as? String) == cookieOrg }
            ?? orgs.first { (($0["capabilities"] as? [String]) ?? []).contains("chat") }
            ?? orgs[0]
        guard let uuid = preferred["uuid"] as? String else { return cookieOrg }
        ud.set(uuid, forKey: Self.orgIDKey)
        ud.set(Date(), forKey: Self.orgIDDateKey)
        ud.set(Self.planName(for: preferred), forKey: Self.planKey)
        return uuid
    }

    /// "Pro", "Max 5x", "Max 20x", "Team", … from an /api/organizations entry.
    static func planName(for org: [String: Any]) -> String {
        if let name = org["plan_display_name"] as? String, !name.isEmpty { return name }
        let tier = ((org["rate_limit_tier"] as? String) ?? "").lowercased()
        let caps = Set(((org["capabilities"] as? [String]) ?? []).map { $0.lowercased() })
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        if caps.contains("claude_max") || tier.contains("max") { return "Max" }
        if caps.contains("claude_pro") || tier.contains("pro") { return "Pro" }
        if tier.contains("enterprise") || caps.contains("enterprise") { return "Enterprise" }
        if tier.contains("team") || caps.contains("raven") { return "Team" }
        return "Free"
    }

    // Fallback: same API calls but from inside the logged-in page context,
    // which inherits WebKit's TLS/cookie handling (gets past Cloudflare).
    private func fetchViaWebView() async -> FetchResult {
        let script = """
        try {
            const headers = { 'Accept': 'application/json' };
            const orgRes = await fetch('/api/organizations', { credentials: 'include', headers });
            if (orgRes.status === 401 || orgRes.status === 403) return JSON.stringify({ error: 'auth' });
            if (!orgRes.ok) return JSON.stringify({ error: 'http_' + orgRes.status });
            const orgs = await orgRes.json();
            const orgObj = Array.isArray(orgs) && orgs.length
                ? (orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0])
                : null;
            const org = orgObj && orgObj.uuid;
            if (!org) return JSON.stringify({ error: 'noorg' });
            const r = await fetch('/api/organizations/' + org + '/usage', { credentials: 'include', headers });
            if (r.status === 401 || r.status === 403) return JSON.stringify({ error: 'auth' });
            if (!r.ok) return JSON.stringify({ error: 'http_' + r.status });
            return JSON.stringify({ data: await r.json(), org: {
                uuid: orgObj.uuid, capabilities: orgObj.capabilities,
                rate_limit_tier: orgObj.rate_limit_tier, plan_display_name: orgObj.plan_display_name } });
        } catch (e) {
            return JSON.stringify({ error: String(e) });
        }
        """
        guard let raw = await webFetcher.run(
                pageURL: URL(string: "https://claude.ai/")!, script: script),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            webFetcher.invalidatePage()
            return .failure
        }
        if (obj["error"] as? String) == "auth" { return .authExpired }
        guard let payload = obj["data"] as? [String: Any],
              var usage = Self.parseUsage(payload) else {
            webFetcher.invalidatePage()
            return .failure
        }
        if let org = obj["org"] as? [String: Any] {
            UserDefaults.standard.set(Self.planName(for: org), forKey: Self.planKey)
        }
        usage.planName = UserDefaults.standard.string(forKey: Self.planKey)
        return .success(usage)
    }

    private static func parseUsage(_ obj: [String: Any]) -> ProviderUsage? {
        var u = ProviderUsage(fetchedAt: Date())
        if let fh = obj["five_hour"] as? [String: Any] {
            u.sessionPct = providerPct(fh["utilization"])
            u.sessionResetAt = providerDate(fh["resets_at"])
        }
        if let sd = obj["seven_day"] as? [String: Any] {
            u.weeklyPct = providerPct(sd["utilization"])
            u.weeklyResetAt = providerDate(sd["resets_at"])
        }

        // Model-scoped weekly caps (e.g. Fable). Present in the structured
        // `limits` array as kind == "weekly_scoped" with scope.model.display_name.
        // Auto-surfaces whatever models Anthropic reports — Fable today, others later.
        var lanes: [ProviderQuotaLane] = []
        if let limits = obj["limits"] as? [[String: Any]] {
            for lim in limits {
                guard (lim["kind"] as? String) == "weekly_scoped" else { continue }
                let scope = lim["scope"] as? [String: Any] ?? [:]
                let model = scope["model"] as? [String: Any] ?? [:]
                let label = ((model["display_name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                guard let pct = providerPct(lim["percent"]) ?? providerPct(lim["utilization"]) else {
                    continue
                }
                let modelID = (model["id"] as? String)
                    ?? label.lowercased().replacingOccurrences(
                        of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                lanes.append(ProviderQuotaLane(
                    id: "weekly_scoped:\(modelID)",
                    label: label,
                    group: "weekly_scoped",
                    pct: pct,
                    resetAt: providerDate(lim["resets_at"])
                ))
            }
        }

        // Older top-level keys (seven_day_sonnet / seven_day_fable / …) still
        // appear on some accounts; only use them when the limits array did not
        // already cover the same label.
        let legacyKeys: [(key: String, label: String)] = [
            ("seven_day_fable", "Fable"),
            ("seven_day_sonnet", "Sonnet"),
            ("seven_day_opus", "Opus"),
        ]
        for entry in legacyKeys {
            if lanes.contains(where: {
                $0.label.caseInsensitiveCompare(entry.label) == .orderedSame
            }) { continue }
            guard let block = obj[entry.key] as? [String: Any] else { continue }
            guard let pct = providerPct(block["utilization"]) ?? providerPct(block["percent"]) else {
                continue
            }
            lanes.append(ProviderQuotaLane(
                id: entry.key,
                label: entry.label,
                group: "weekly_scoped",
                pct: pct,
                resetAt: providerDate(block["resets_at"])
            ))
        }

        if !lanes.isEmpty { u.quotaLanes = lanes }
        guard u.sessionPct != nil || u.weeklyPct != nil || !lanes.isEmpty else { return nil }
        return u
    }
}
