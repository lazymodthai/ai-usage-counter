import Foundation
import WebKit

// Antigravity quota via the local Antigravity language server. This mirrors the
// quota monitor extension's "Local Monitoring" path:
//   scan language_server command lines for --csrf_token
//   find that process' listening ports
//   POST /exa.language_server_pb.LanguageServerService/GetUserStatus
@MainActor
final class AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity
    private let dataStore = ProviderDataStores.store(for: .antigravity)

    private static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    // MARK: - Auth

    func checkAuth() async -> AuthState {
        if !(await Self.discoverServersAsync()).isEmpty { return .signedIn }
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
            loginCheck: { _, _ in
                if !(await Self.discoverServersAsync()).isEmpty { return true }
                return await store.hasCookie(domain: "google.com") {
                    ["SID", "__Secure-1PSID", "SAPISID"].contains($0.name)
                }
            }
        ), onComplete: onComplete)
    }

    func signOut() async {
        await dataStore.wipeAllData()
    }

    func releaseIdleResources() {}

    // MARK: - Fetch

    func fetchUsage() async -> FetchResult {
        for server in await Self.discoverServersAsync() {
            for port in await Self.listeningPortsAsync(forPID: server.pid) {
                guard let payload = await Self.fetchUserStatus(port: port, csrfToken: server.csrfToken),
                      let usage = Self.parseUserStatus(payload) else {
                    continue
                }
                return .success(usage)
            }
        }
        return .failure
    }

    // MARK: - Local process discovery

    private struct ServerCandidate {
        let pid: Int
        let csrfToken: String
        let score: Int
    }

    private static func discoverServersAsync() async -> [ServerCandidate] {
        await Task.detached(priority: .utility) {
            discoverServers()
        }.value
    }

    private static func listeningPortsAsync(forPID pid: Int) async -> [Int] {
        await Task.detached(priority: .utility) {
            listeningPorts(forPID: pid)
        }.value
    }

    nonisolated private static func discoverServers() -> [ServerCandidate] {
        let output = runCommand("/bin/ps", ["ax", "-o", "pid=,ppid=,command="])
        let lines = output.split(separator: "\n").map(String.init)
        let currentWorkspaceHint = "project_claude_usage_counter"

        return lines.compactMap { line -> ServerCandidate? in
            guard line.contains("language_server"),
                  line.contains("--csrf_token"),
                  line.contains("antigravity") else { return nil }
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard let pidText = parts.first, let pid = Int(pidText) else { return nil }
            guard let token = firstMatch(in: line, pattern: #"--csrf_token[=\s]+([A-Za-z0-9-]+)"#) else {
                return nil
            }

            var score = 0
            if line.contains(currentWorkspaceHint) { score += 100 }
            if line.contains("--app_data_dir antigravity-ide") { score += 20 }
            if line.contains("--enable_lsp") { score += 10 }
            if line.contains("--standalone") { score += 5 }
            return ServerCandidate(pid: pid, csrfToken: token, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    nonisolated private static func listeningPorts(forPID pid: Int) -> [Int] {
        let output = runCommand("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", "\(pid)"])
        return output
            .split(separator: "\n")
            .compactMap { line -> Int? in
                guard let port = firstMatch(in: String(line), pattern: #":(\d+)\s+\(LISTEN\)"#) else {
                    return nil
                }
                return Int(port)
            }
    }

    nonisolated private static func runCommand(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    process.terminate()
                }
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    nonisolated private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Local API

    private static func fetchUserStatus(port: Int, csrfToken: String) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(Self.userStatusPath)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "locale": "en",
            ]
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        } catch {
            return nil
        }
    }

    private static func parseUserStatus(_ root: [String: Any]) -> ProviderUsage? {
        guard let userStatus = root["userStatus"] as? [String: Any],
              let configData = userStatus["cascadeModelConfigData"] as? [String: Any],
              let modelConfigs = configData["clientModelConfigs"] as? [[String: Any]] else {
            return nil
        }

        let now = Date()
        let lanes = modelConfigs.compactMap { item -> ProviderQuotaLane? in
            guard let label = item["label"] as? String else { return nil }
            let quotaInfo = item["quotaInfo"] as? [String: Any] ?? [:]
            let remainingFraction = providerNum(quotaInfo["remainingFraction"]) ?? 0
            let remainingPct = min(max(remainingFraction * 100, 0), 100)
            let usedPct = 100 - remainingPct
            let resetAt = providerDate(quotaInfo["resetTime"])

            return ProviderQuotaLane(
                id: stableID(for: item, fallback: label),
                label: label,
                group: modelGroup(for: label),
                pct: usedPct,
                resetAt: resetAt,
                resetText: resetAt.map { formatDuration($0.timeIntervalSince(now)) }
            )
        }

        guard !lanes.isEmpty else { return nil }
        var usage = ProviderUsage(fetchedAt: now)
        usage.planName = ((userStatus["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        usage.quotaLanes = lanes
        return usage
    }

    private static func stableID(for item: [String: Any], fallback: String) -> String {
        if let model = (item["modelOrAlias"] as? [String: Any])?["model"] as? String {
            return model
        }
        return fallback.lowercased().replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        )
    }

    private static func modelGroup(for label: String) -> String? {
        if label.localizedCaseInsensitiveContains("Gemini") { return "Gemini" }
        if label.localizedCaseInsensitiveContains("Claude") { return "Claude" }
        if label.localizedCaseInsensitiveContains("GPT") { return "OpenAI" }
        return nil
    }

    private static func formatDuration(_ secs: TimeInterval) -> String {
        let total = max(0, Int(secs))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
