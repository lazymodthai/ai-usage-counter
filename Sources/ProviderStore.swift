import Foundation
import AppKit

@MainActor
final class ProviderStore: ObservableObject {
    // MARK: - Published state
    @Published var usages: [ProviderID: ProviderUsage] = [:]
    @Published var authStates: [ProviderID: AuthState] = [:]
    @Published private(set) var fetchFailures: [ProviderID: Int] = [:]
    @Published private(set) var fetchingProviders: Set<ProviderID> = []
    @Published var isLoading: Bool = false
    @Published var showSettings: Bool = false

    /// Which provider drives the menu bar. Selectable among connected providers.
    @Published var menubarSource: ProviderID {
        didSet {
            UserDefaults.standard.set(menubarSource.rawValue, forKey: "menubarSource")
            // The newly selected provider should be fresh
            if authStates[menubarSource] == .signedIn { nextFetchAt[menubarSource] = Date() }
            updateStatusBar(force: true)
        }
    }

    // MARK: - Claude local JSONL fallback (offline estimate)
    @Published var data: UsageData = .init()
    @Published var sessionTokenLimit: Int {
        didSet { UserDefaults.standard.set(sessionTokenLimit, forKey: "sessionTokenLimit") }
    }
    @Published var weeklyTokenLimit: Int {
        didSet { UserDefaults.standard.set(weeklyTokenLimit, forKey: "weeklyTokenLimit") }
    }
    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }

    // MARK: - Internals
    let providers: [ProviderID: any UsageProvider]
    weak var statusItem: NSStatusItem?

    private var nextFetchAt: [ProviderID: Date] = [:]
    private var tickTimer: Timer?
    private var lastStatusTitle = ""
    private var watcher: FileWatcher?
    private var sleepObservers: [NSObjectProtocol] = []

    private static let cachedUsagesKey = "cachedProviderUsages"

    var connectedProviders: [ProviderID] {
        ProviderID.allCases.filter { authStates[$0] == .signedIn }
    }

    init() {
        let ud = UserDefaults.standard

        if ud.integer(forKey: "configVersion") < 2 {
            ud.removeObject(forKey: "sessionTokenLimit")
            ud.removeObject(forKey: "weeklyTokenLimit")
            ud.set(2, forKey: "configVersion")
        }

        sessionTokenLimit = ud.object(forKey: "sessionTokenLimit") != nil
            ? ud.integer(forKey: "sessionTokenLimit") : 0
        weeklyTokenLimit  = ud.object(forKey: "weeklyTokenLimit")  != nil
            ? ud.integer(forKey: "weeklyTokenLimit")  : 0
        refreshInterval   = ud.object(forKey: "refreshInterval")   != nil
            ? max(30, ud.double(forKey: "refreshInterval")) : 60.0

        menubarSource = ud.string(forKey: "menubarSource").flatMap(ProviderID.init) ?? .claude

        providers = [
            .claude: ClaudeProvider(),
            .codex:  CodexProvider(),
            .gemini: GeminiProvider(),
            .antigravity: AntigravityProvider(),
        ]

        // Show last known values immediately on launch (stale flag shows in UI)
        if let raw = ud.data(forKey: Self.cachedUsagesKey),
           let cached = try? JSONDecoder().decode([String: ProviderUsage].self, from: raw) {
            for (k, v) in cached {
                if let id = ProviderID(rawValue: k) { usages[id] = v }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Claude local fallback: watch Claude Code's JSONL files
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
        watcher = FileWatcher(path: claudeDir) { [weak self] in
            Task { @MainActor in self?.refreshLocal() }
        }
        refreshLocal()

        Task { @MainActor in
            await refreshAuthStates()
            scheduleInitialFetches()
        }

        startTick()
        observeSleepWake()
    }

    private func refreshAuthStates() async {
        for (id, p) in providers {
            // Don't downgrade an expired state on a cookie-presence check —
            // expired cookies still exist; only a successful fetch clears it.
            if authStates[id] == .expired { continue }
            authStates[id] = await p.checkAuth()
        }
        ensureValidMenubarSource()
    }

    private func scheduleInitialFetches() {
        // Stagger so providers don't all spin up at once
        var delay: TimeInterval = 0
        let ordered = [menubarSource] + ProviderID.allCases.filter { $0 != menubarSource }
        for id in ordered where authStates[id] == .signedIn {
            nextFetchAt[id] = Date().addingTimeInterval(delay)
            delay += 3
        }
    }

    // MARK: - Tick loop (1s): countdowns, due fetches, status bar

    private func startTick() {
        tickTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.2
        tickTimer = t
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        let now = Date()
        for id in ProviderID.allCases {
            guard let due = nextFetchAt[id], due <= now else { continue }
            fetch(id)
        }
        updateStatusBar()
    }

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopTick() }
        })
        sleepObservers.append(nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.startTick()
                self.refreshAll()
            }
        })
    }

    // MARK: - Fetching

    func refreshAll() {
        refreshLocal()
        var delay: TimeInterval = 0
        for id in ProviderID.allCases where authStates[id] == .signedIn {
            nextFetchAt[id] = Date().addingTimeInterval(delay)
            delay += 2
        }
    }

    private func fetch(_ id: ProviderID) {
        guard !fetchingProviders.contains(id),
              let provider = providers[id],
              authStates[id] == .signedIn else {
            nextFetchAt[id] = nil
            return
        }
        fetchingProviders.insert(id)
        nextFetchAt[id] = nil
        if id == menubarSource { isLoading = true }

        Task { @MainActor in
            let result = await provider.fetchUsage()
            self.fetchingProviders.remove(id)
            if id == self.menubarSource { self.isLoading = false }

            switch result {
            case .success(let usage):
                self.usages[id] = usage
                self.fetchFailures[id] = 0
                self.persistUsages()
                self.scheduleNext(id)
            case .authExpired:
                self.authStates[id] = .expired
                self.ensureValidMenubarSource()
                // Stop polling — resumes after the user re-authenticates
            case .failure:
                self.fetchFailures[id, default: 0] += 1
                self.scheduleNext(id)
            }
            self.releaseIdleResources(after: id)
            self.updateStatusBar(force: true)
        }
    }

    private func scheduleNext(_ id: ProviderID) {
        let now = Date()

        // At limit → no point polling; wait for the reset (+grace), countdown runs locally
        if let usage = usages[id], let reset = usage.nearestLimitReset {
            nextFetchAt[id] = max(reset.addingTimeInterval(5), now.addingTimeInterval(5))
            return
        }

        let failures = fetchFailures[id] ?? 0
        if failures > 0 {
            // Backoff: 60s → 2m → 4m → 8m → 10m cap
            let backoff = min(600.0, 60.0 * pow(2.0, Double(failures - 1)))
            nextFetchAt[id] = now.addingTimeInterval(backoff)
            return
        }

        // Menu bar provider polls fast; background providers slowly
        let interval = id == menubarSource ? max(30, refreshInterval) : 600
        nextFetchAt[id] = now.addingTimeInterval(interval)
    }

    /// Free hidden-WebView memory for providers that aren't on the menu bar.
    /// They reload their page on the next (10-minute) fetch.
    private func releaseIdleResources(after id: ProviderID) {
        guard id != menubarSource else { return }
        switch providers[id] {
        case let p as CodexProvider:  p.releaseIdleResources()
        case let p as GeminiProvider: p.releaseIdleResources()
        case let p as AntigravityProvider: p.releaseIdleResources()
        case let p as ClaudeProvider: p.releaseIdleResources()
        default: break
        }
    }

    private func persistUsages() {
        var dict: [String: ProviderUsage] = [:]
        for (id, u) in usages { dict[id.rawValue] = u }
        if let raw = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(raw, forKey: Self.cachedUsagesKey)
        }
    }

    // MARK: - Auth actions

    func presentLogin(_ id: ProviderID) {
        providers[id]?.presentLogin { [weak self] in
            Task { @MainActor in
                guard let self, let provider = self.providers[id] else { return }
                let state = await provider.checkAuth()
                self.authStates[id] = state
                if state == .signedIn {
                    self.nextFetchAt[id] = Date()
                    // First connected provider takes the menu bar automatically
                    if self.connectedProviders == [id] {
                        self.menubarSource = id
                    }
                }
                self.updateStatusBar(force: true)
            }
        }
    }

    func signOut(_ id: ProviderID) {
        Task { @MainActor in
            await providers[id]?.signOut()
            authStates[id] = .signedOut
            usages[id] = nil
            nextFetchAt[id] = nil
            fetchFailures[id] = nil
            persistUsages()
            ensureValidMenubarSource()
            updateStatusBar(force: true)
        }
    }

    /// If the current menu bar provider is gone, fall back to the first connected
    /// one — or Claude, which still has the local JSONL estimate.
    private func ensureValidMenubarSource() {
        guard authStates[menubarSource] != .signedIn else { return }
        menubarSource = connectedProviders.first ?? .claude
    }

    // MARK: - Claude local fallback

    func refreshLocal() {
        Task { @MainActor in
            self.data = await UsageParser.parse()
            self.updateStatusBar(force: true)
        }
    }

    var effectiveSessionLimit: Int {
        sessionTokenLimit > 0 ? sessionTokenLimit : max(1, data.detectedSessionLimit)
    }
    var effectiveWeeklyLimit: Int {
        weeklyTokenLimit > 0 ? weeklyTokenLimit : max(1, data.detectedWeeklyLimit)
    }

    /// True when the Claude rows are showing local-file estimates instead of live API data.
    var claudeUsingLocal: Bool {
        authStates[.claude] != .signedIn || usages[.claude] == nil
    }

    // MARK: - Status bar

    func updateStatusBar(force: Bool = false) {
        guard let button = statusItem?.button else { return }
        let title = " \(sessionDisplay(for: menubarSource)) | \(weeklyDisplay(for: menubarSource))"
        guard force || title != lastStatusTitle else { return }
        lastStatusTitle = title

        if let img = NSImage(systemSymbolName: menubarSource.symbolName, accessibilityDescription: "AI Usage") {
            img.size = NSSize(width: 14, height: 14)
            button.image = img
        }
        button.title = title
        button.toolTip = "\(menubarSource.displayName) usage — session | weekly"
    }

    // MARK: - Display formatters (menu bar + popup)

    func sessionDisplay(for id: ProviderID) -> String {
        if authStates[id] == .signedIn, let u = usages[id] {
            if u.sessionAtLimit, let reset = u.sessionResetAt, reset > Date() {
                return formatSessionCountdown(reset.timeIntervalSinceNow)
            }
            if let pct = u.sessionPct {
                return String(format: "%.2f%%", pct)
            }
        }
        if id == .claude { return localSessionDisplay() }
        return "—"
    }

    func weeklyDisplay(for id: ProviderID) -> String {
        if authStates[id] == .signedIn, let u = usages[id] {
            if u.weeklyAtLimit, let reset = u.weeklyResetAt, reset > Date() {
                return formatResetClock(reset)
            }
            if let pct = u.weeklyPct {
                return String(format: "%.2f%%", pct)
            }
        }
        if id == .claude { return localWeeklyDisplay() }
        return "—"
    }

    private func localSessionDisplay() -> String {
        if let block = data.currentBlock, block.isActive {
            let frac = Double(block.tokens) / Double(effectiveSessionLimit)
            if frac >= 0.9999 {
                return formatSessionCountdown(block.timeUntilReset)
            }
            return String(format: "%.2f%%", min(frac, 1.0) * 100)
        }
        return "0.00%"
    }

    private func localWeeklyDisplay() -> String {
        let frac = Double(data.weeklyBlock.tokens) / Double(effectiveWeeklyLimit)
        if frac >= 0.9999 {
            let reset = Date().addingTimeInterval(data.weeklyBlock.timeUntilReset)
            return formatResetClock(reset)
        }
        return String(format: "%.2f%%", min(frac, 1.0) * 100)
    }

    /// Absolute weekly reset, e.g. "Tue 5:00AM" — matches the providers' web UIs.
    func formatResetClock(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "EEE h:mma"
        df.amSymbol = "AM"
        df.pmSymbol = "PM"
        return df.string(from: date)
    }

    /// Session reset (max 5h). Shown as ">4h", "<4h", "<3h", "<2h", "59m"…"1m", "59s"…"0s"
    func formatSessionCountdown(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let h = m / 60
        if h >= 4 { return ">4h" }
        if h >= 3 { return "<4h" }
        if h >= 2 { return "<3h" }
        if h >= 1 { return "<2h" }
        return "\(m)m"
    }

    /// Weekly reset. If > 1 day: "1d 22h", "4d 22h". Otherwise same as session.
    func formatWeeklyCountdown(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs))
        let d = s / 86400
        if d >= 1 {
            let h = (s % 86400) / 3600
            return "\(d)d \(h)h"
        }
        return formatSessionCountdown(secs)
    }
}

// MARK: - Per-provider bar view models (popup)

struct UsageBarVM {
    var fraction: Double
    var usedText: String
    var limitText: String
    var resetLabel: String
    var isActive: Bool
}

extension ProviderStore {
    func sessionBar(for id: ProviderID) -> UsageBarVM? {
        if authStates[id] == .signedIn, let u = usages[id], let pct = u.sessionPct {
            let atLimit = u.sessionAtLimit
            var reset = "—"
            if let r = u.sessionResetAt, r > Date() {
                reset = "Resets in \(formatDuration(r.timeIntervalSinceNow))"
            }
            return UsageBarVM(
                fraction: min(pct / 100.0, 1.0),
                usedText: atLimit ? sessionDisplay(for: id) : String(format: "%.1f%%", pct),
                limitText: atLimit ? "LIMIT REACHED" : "100%",
                resetLabel: reset,
                isActive: true
            )
        }
        if id == .claude { return localSessionBar() }
        return nil
    }

    func weeklyBar(for id: ProviderID) -> UsageBarVM? {
        if authStates[id] == .signedIn, let u = usages[id], let pct = u.weeklyPct {
            let atLimit = u.weeklyAtLimit
            var reset = "—"
            if let r = u.weeklyResetAt, r > Date() {
                reset = "Resets \(formatResetClock(r))"
            }
            return UsageBarVM(
                fraction: min(pct / 100.0, 1.0),
                usedText: String(format: "%.1f%%", pct),
                limitText: atLimit ? "LIMIT REACHED" : "100%",
                resetLabel: reset,
                isActive: true
            )
        }
        if id == .claude { return localWeeklyBar() }
        return nil
    }

    func quotaBars(for id: ProviderID) -> [(lane: ProviderQuotaLane, vm: UsageBarVM)] {
        guard authStates[id] == .signedIn, let usage = usages[id] else { return [] }
        return (usage.quotaLanes ?? []).map { lane in
            let reset: String
            if let resetAt = lane.resetAt, resetAt > Date() {
                reset = "Resets in \(formatDuration(resetAt.timeIntervalSinceNow))"
            } else if let resetText = lane.resetText, !resetText.isEmpty {
                reset = resetText
            } else {
                reset = "—"
            }
            let atLimit = lane.pct >= 99.99
            let vm = UsageBarVM(
                fraction: min(lane.pct / 100.0, 1.0),
                usedText: String(format: "%.1f%%", lane.pct),
                limitText: atLimit ? "LIMIT REACHED" : "100%",
                resetLabel: reset,
                isActive: true
            )
            return (lane, vm)
        }
    }

    private func localSessionBar() -> UsageBarVM {
        guard let block = data.currentBlock, block.isActive else {
            return UsageBarVM(fraction: 0, usedText: "—", limitText: "", resetLabel: "No active session", isActive: false)
        }
        let frac = min(Double(block.tokens) / Double(effectiveSessionLimit), 1.0)
        let atLimit = frac >= 0.9999
        let fmt = DateFormatter(); fmt.timeStyle = .short
        let resetLabel = block.timeUntilReset < 60
            ? "Resets in < 1m"
            : "Resets at \(fmt.string(from: block.resetTime)) (\(formatDuration(block.timeUntilReset)))"
        return UsageBarVM(
            fraction: frac,
            usedText: atLimit ? localSessionDisplayPublic() : formatTokens(block.tokens),
            limitText: atLimit ? "LIMIT REACHED" : formatTokens(effectiveSessionLimit) + " tokens",
            resetLabel: resetLabel,
            isActive: true
        )
    }

    private func localWeeklyBar() -> UsageBarVM {
        let frac = min(Double(data.weeklyBlock.tokens) / Double(effectiveWeeklyLimit), 1.0)
        let atLimit = frac >= 0.9999
        let reset = Date().addingTimeInterval(data.weeklyBlock.timeUntilReset)
        return UsageBarVM(
            fraction: frac,
            usedText: atLimit ? "100.0%" : formatTokens(data.weeklyBlock.tokens),
            limitText: atLimit ? "LIMIT REACHED" : formatTokens(effectiveWeeklyLimit) + " tokens",
            resetLabel: "Resets \(formatResetClock(reset))",
            isActive: true
        )
    }

    private func localSessionDisplayPublic() -> String { sessionDisplay(for: .claude) }
}

// MARK: - Generic formatting

extension ProviderStore {
    func formatTokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1fG", d / 1_000_000_000) }
        if d >= 1_000_000     { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000         { return String(format: "%.0fK", d / 1_000) }
        return "\(n)"
    }

    func formatCost(_ v: Double) -> String { String(format: "$%.2f", v) }

    func formatDuration(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s < 60 { return "\(s)s" }
        let m = s / 60; let h = m / 60
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
}
