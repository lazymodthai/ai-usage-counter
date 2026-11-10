import Foundation
import AppKit
import SwiftUI

// Records Claude usage history from live API snapshots.
// claude.ai only exposes the *current* percentages, so history is built by
// remembering the peak % seen for each 5-hour session window and each weekly
// window (both identified by their resets_at). Only time the app was running
// is captured; sessions with no activity never appear.

struct SessionRecord: Codable, Identifiable, Equatable {
    var resetAt: Date
    var firstSeen: Date
    var lastSeen: Date
    var peakPct: Double

    var id: Date { resetAt }
    var start: Date { resetAt.addingTimeInterval(-UsageHistoryStore.sessionLength) }
}

struct WeekRecord: Codable, Identifiable, Equatable {
    var resetAt: Date
    var firstSeen: Date
    var lastSeen: Date
    var peakPct: Double
    /// Model-scoped weekly caps (e.g. "Fable") → peak %.
    var scopedPeaks: [String: Double] = [:]

    var id: Date { resetAt }
    var start: Date { resetAt.addingTimeInterval(-UsageHistoryStore.weekLength) }
}

private struct HistoryFile: Codable {
    var version = 1
    var sessions: [SessionRecord] = []
    var weeks: [WeekRecord] = []
}

@MainActor
final class UsageHistoryStore: ObservableObject {
    nonisolated static let sessionLength: TimeInterval = 5 * 3600
    nonisolated static let weekLength: TimeInterval = 7 * 86_400
    /// resets_at jitters by milliseconds–seconds between calls; treat nearby values as the same window.
    private static let sessionTolerance: TimeInterval = 15 * 60
    private static let weekTolerance: TimeInterval = 3 * 3600
    private static let retention: TimeInterval = 400 * 86_400

    @Published private(set) var sessions: [SessionRecord] = []   // newest first
    @Published private(set) var weeks: [WeekRecord] = []         // newest first

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsageCounter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("claude-history.json")
        load()
    }

    var recordingSince: Date? {
        (sessions.map(\.firstSeen) + weeks.map(\.firstSeen)).min()
    }

    func sessions(in week: WeekRecord) -> [SessionRecord] {
        // A session belongs to the week it started in.
        sessions.filter { $0.start >= week.start && $0.start < week.resetAt }
    }

    // MARK: - Recording

    func record(_ usage: ProviderUsage) {
        let now = usage.fetchedAt
        var changed = false

        if let reset = usage.sessionResetAt, let pct = usage.sessionPct, pct > 0 {
            if let i = sessions.firstIndex(where: { abs($0.resetAt.timeIntervalSince(reset)) < Self.sessionTolerance }) {
                sessions[i].lastSeen = now
                if pct > sessions[i].peakPct { sessions[i].peakPct = pct; changed = true }
            } else {
                sessions.insert(SessionRecord(resetAt: reset, firstSeen: now, lastSeen: now, peakPct: pct), at: 0)
                sessions.sort { $0.resetAt > $1.resetAt }
                changed = true
            }
        }

        if let reset = usage.weeklyResetAt, let pct = usage.weeklyPct {
            let scoped = (usage.quotaLanes ?? []).filter { $0.group == "weekly_scoped" }
            let i: Int
            if let found = weeks.firstIndex(where: { abs($0.resetAt.timeIntervalSince(reset)) < Self.weekTolerance }) {
                i = found
            } else {
                weeks.insert(WeekRecord(resetAt: reset, firstSeen: now, lastSeen: now, peakPct: pct), at: 0)
                weeks.sort { $0.resetAt > $1.resetAt }
                i = weeks.firstIndex { $0.resetAt == reset }!
                changed = true
            }
            weeks[i].lastSeen = now
            if pct > weeks[i].peakPct { weeks[i].peakPct = pct; changed = true }
            for lane in scoped where lane.pct > (weeks[i].scopedPeaks[lane.label] ?? -1) {
                weeks[i].scopedPeaks[lane.label] = lane.pct
                changed = true
            }
        }

        // Only touch disk when a peak or a new window appears (not every poll).
        if changed { prune(); save() }
    }

    // MARK: - Persistence

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        sessions.removeAll { $0.resetAt < cutoff }
        weeks.removeAll { $0.resetAt < cutoff }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(HistoryFile.self, from: data) else { return }
        sessions = file.sessions.sorted { $0.resetAt > $1.resetAt }
        weeks = file.weeks.sorted { $0.resetAt > $1.resetAt }
    }

    private func save() {
        let file = HistoryFile(sessions: sessions, weeks: weeks)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Window

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show(history: UsageHistoryStore) {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Claude Usage History"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Color.appBg)
        w.contentViewController = NSHostingController(rootView: HistoryView(history: history))
        w.setContentSize(NSSize(width: 460, height: 560))
        w.minSize = NSSize(width: 380, height: 300)
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

struct HistoryView: View {
    @ObservedObject var history: UsageHistoryStore
    @State private var expanded: Set<Date> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.tint(for: .claude))
                Text("Claude history")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if let since = history.recordingSince {
                    Text("Recording since \(HistoryFormat.day.string(from: since))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().overlay(Color.divider)

            if history.weeks.isEmpty && history.sessions.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No history yet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text("Usage is recorded while the app is running and signed in to Claude.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(history.weeks) { week in
                            WeekCard(week: week,
                                     sessions: history.sessions(in: week),
                                     isExpanded: expanded.contains(week.id)) {
                                if expanded.contains(week.id) { expanded.remove(week.id) }
                                else { expanded.insert(week.id) }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .background(Color.appBg)
        .onAppear {
            if let current = history.weeks.first { expanded.insert(current.id) }
        }
    }
}

private struct WeekCard: View {
    let week: WeekRecord
    let sessions: [SessionRecord]
    let isExpanded: Bool
    let toggle: () -> Void

    private var isCurrent: Bool { week.resetAt > Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .frame(width: 10)
                        Text(HistoryFormat.weekRange(week))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        if isCurrent {
                            Text("THIS WEEK")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.accent)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accent.opacity(0.15))
                                .cornerRadius(3)
                        }
                        Spacer()
                        Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    HistoryBar(label: "Weekly", pct: week.peakPct, color: .sonnetCyan)
                    ForEach(week.scopedPeaks.keys.sorted(), id: \.self) { label in
                        HistoryBar(label: label, pct: week.scopedPeaks[label] ?? 0,
                                   color: Color(red: 0.72, green: 0.45, blue: 1.0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if sessions.isEmpty {
                    Text("No sessions recorded")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.leading, 16)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sessions) { s in
                            SessionRow(session: s)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(10)
        .background(Color.cardBg)
        .cornerRadius(8)
    }
}

private struct SessionRow: View {
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(HistoryFormat.sessionRange(session))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(session.resetAt > Date() ? 0.95 : 0.7))
                .frame(width: 170, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color.accent)
                        .frame(width: geo.size.width * min(session.peakPct / 100, 1))
                }
            }
            .frame(height: 5)
            Text(HistoryFormat.pct(session.peakPct))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accent)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct HistoryBar: View {
    let label: String
    let pct: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 60, alignment: .leading)
                .padding(.leading, 16)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color).frame(width: geo.size.width * min(pct / 100, 1))
                }
            }
            .frame(height: 5)
            Text(HistoryFormat.pct(pct))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

enum HistoryFormat {
    static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"; return f
    }()
    private static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"; return f
    }()
    private static let sessionDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM HH:mm"; return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"; return f
    }()

    static func weekRange(_ w: WeekRecord) -> String {
        "\(shortDay.string(from: w.start)) – \(shortDay.string(from: w.resetAt.addingTimeInterval(-1)))"
    }

    static func sessionRange(_ s: SessionRecord) -> String {
        "\(sessionDay.string(from: s.start))–\(clock.string(from: s.resetAt))"
    }

    static func pct(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f%%", v) : String(format: "%.1f%%", v)
    }
}
