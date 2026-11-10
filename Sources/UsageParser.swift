import Foundation

private struct RawRecord: Sendable {
    let timestamp: Date
    let model: String
    let usage: TokenUsage
    let toolCalls: Int
    let cost: Double
    let isRateLimit: Bool       // "You've hit your limit"
    let isExtraUsage: Bool      // "You're out of extra usage"
}

enum UsageParser {
    static func parse() async -> UsageData {
        await Task.detached(priority: .utility) { parseSync() }.value
    }

    private static func parseSync() -> UsageData {
        var data = UsageData()
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard fm.fileExists(atPath: claudeDir.path) else { return data }

        var records: [RawRecord] = []
        var sessionIDs = Set<String>()

        guard let enumerator = fm.enumerator(
            at: claudeDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return data }

        var seenPaths = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if !name.hasPrefix("agent-") {
                sessionIDs.insert(url.deletingLastPathComponent().lastPathComponent + "/" + name)
            }
            seenPaths.insert(url.path)
            records.append(contentsOf: cachedRecords(for: url))
        }
        pruneCache(keeping: seenPaths)

        data.totalSessions = sessionIDs.count
        guard !records.isEmpty else { return data }

        let sorted = records.sorted { $0.timestamp < $1.timestamp }

        // Aggregate period stats, last7days, weekly, billing blocks
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? todayStart
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? todayStart

        var last7Dict = [Date: DayStats]()
        for i in 0..<7 {
            let d = cal.date(byAdding: .day, value: -i, to: todayStart)!
            last7Dict[d] = DayStats(date: d)
        }

        for r in sorted {
            // First usage date
            if data.firstUsageDate == nil || r.timestamp < data.firstUsageDate! {
                data.firstUsageDate = r.timestamp
            }

            let rDate = cal.startOfDay(for: r.timestamp)

            if r.timestamp >= monthStart {
                data.month.add(model: r.model, cost: r.cost, usage: r.usage, tools: r.toolCalls)
                if r.timestamp >= weekStart {
                    data.week.add(model: r.model, cost: r.cost, usage: r.usage, tools: r.toolCalls)
                }
                if r.timestamp >= todayStart {
                    data.today.add(model: r.model, cost: r.cost, usage: r.usage, tools: r.toolCalls)
                }
            }

            if var day = last7Dict[rDate] {
                day.messages += 1
                day.cost += r.cost
                day.tokens += r.usage.total
                last7Dict[rDate] = day
            }
        }

        data.last7Days = last7Dict.values.sorted { $0.date < $1.date }

        // Build 5-hour billing blocks
        let blocks = buildBillingBlocks(from: sorted)

        // Detect limits from actual rate_limit error events (most accurate method)
        let detected = UsageParser.detectLimitsFromRateLimitEvents(blocks: blocks, sorted: sorted)
        let sessionLimit = detected.session > 0 ? detected.session : (blocks.map { $0.tokens }.max() ?? 1)
        data.detectedSessionLimit = sessionLimit

        // Find current active block
        if var last = blocks.last, last.isActive {
            last.maxTokens = sessionLimit
            data.currentBlock = last
        }

        // Build weekly stats (Mon–Sun)
        let weeklyRecords = sorted.filter { $0.timestamp >= weekStart }
        var wb = WeeklyBlock()
        var weeklyModelSet = Set<String>()
        for r in weeklyRecords {
            if !r.isRateLimit && !r.isExtraUsage {
                wb.tokens += r.usage.total
                wb.cost += r.cost
                wb.messages += 1
                weeklyModelSet.insert(modelDisplayName(r.model))
            }
        }
        wb.models = Array(weeklyModelSet)

        // Weekly limit: use detected extra_usage limit, or fall back to max historical week
        let weeklyLimit = detected.weekly > 0 ? detected.weekly : maxWeeklyTokens(from: sorted, cal: cal)
        wb.maxTokens = weeklyLimit
        data.detectedWeeklyLimit = weeklyLimit
        data.weeklyBlock = wb

        data.lastUpdated = now
        return data
    }

    // MARK: - Billing Blocks (5-hour windows)

    private static func buildBillingBlocks(from sorted: [RawRecord]) -> [BillingBlock] {
        var blocks: [BillingBlock] = []
        var current: BillingBlock? = nil
        let cal = Calendar.current
        let windowDuration: TimeInterval = 5 * 3600

        for r in sorted {
            if var block = current {
                // New block when record falls AFTER current block's 5h window expires
                // (matches ccusage: block boundary = blockStart + 5h, not gap between messages)
                if r.timestamp >= block.blockStart.addingTimeInterval(windowDuration) {
                    blocks.append(block)
                    current = makeBlock(from: r, cal: cal)
                } else {
                    block.tokens += r.usage.total
                    block.cost += r.cost
                    block.messages += 1
                    if !block.models.contains(modelDisplayName(r.model)) {
                        block.models.append(modelDisplayName(r.model))
                    }
                    block.lastActivity = r.timestamp
                    current = block
                }
            } else {
                current = makeBlock(from: r, cal: cal)
            }
        }
        if let block = current { blocks.append(block) }
        return blocks
    }

    private static func makeBlock(from r: RawRecord, cal: Calendar) -> BillingBlock {
        let hourStart = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: r.timestamp)) ?? r.timestamp
        return BillingBlock(
            blockStart: hourStart,
            lastActivity: r.timestamp,
            tokens: r.usage.total,
            cost: r.cost,
            messages: 1,
            models: [modelDisplayName(r.model)]
        )
    }

    // MARK: - Limit detection from rate_limit error events

    /// Derive exact plan limits by finding token counts just before rate_limit errors.
    /// This is the most accurate method — directly reads the plan ceiling from JSONL.
    private static func detectLimitsFromRateLimitEvents(blocks: [BillingBlock], sorted: [RawRecord]) -> (session: Int, weekly: Int) {
        let windowDuration: TimeInterval = 5 * 3600
        var sessionLimitCandidates: [Int] = []
        var weeklyExtraCandidates: [Int] = []

        // Walk through blocks and accumulate tokens until a rate_limit event fires.
        // Tokens accumulated BEFORE the first error in a block = plan limit.
        var current: (start: Date, tokens: Int)? = nil

        for r in sorted {
            if current == nil {
                current = (r.timestamp, 0)
            } else if r.timestamp >= current!.start.addingTimeInterval(windowDuration) {
                current = (r.timestamp, 0)
            }

            if r.isRateLimit, let c = current {
                // tokens before this failed request = limit
                sessionLimitCandidates.append(c.tokens)
            } else if r.isExtraUsage, let c = current {
                weeklyExtraCandidates.append(c.tokens)
            } else {
                current = (current!.start, current!.tokens + r.usage.total)
            }
        }

        // Use the most recent rate_limit value as the current plan's session limit.
        // Ignore outliers that are < 50% of the max detected limit
        // (may occur when weekly budget was already exhausted, reducing per-session allowance).
        let rawSession = sessionLimitCandidates.max() ?? 0
        let filteredSession = sessionLimitCandidates.filter { $0 >= rawSession / 2 }
        let sessionLimit = filteredSession.last ?? rawSession

        let weeklyLimit = weeklyExtraCandidates.last ?? 0

        return (session: sessionLimit, weekly: weeklyLimit)
    }

    // MARK: - Weekly Max (for % calculation, fallback)

    private static func maxWeeklyTokens(from sorted: [RawRecord], cal: Calendar) -> Int {
        guard !sorted.isEmpty else { return 1 }
        var weekGroups = [Date: Int]()
        for r in sorted {
            let ws = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: r.timestamp)) ?? r.timestamp
            weekGroups[ws, default: 0] += r.usage.total
        }
        return weekGroups.values.max() ?? 1
    }

    // MARK: - File Parsing

    // Per-file record cache keyed by (mtime, size). Only files that changed since the
    // last parse are re-read, so an active Claude Code session costs one file, not GBs.
    private struct CacheEntry { let mtime: Date; let size: Int; let records: [RawRecord] }
    private static var fileCache: [String: CacheEntry] = [:]
    private static let cacheLock = NSLock()

    private static func cachedRecords(for url: URL) -> [RawRecord] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1

        cacheLock.lock()
        let hit = fileCache[url.path]
        cacheLock.unlock()
        if let hit, hit.mtime == mtime, hit.size == size { return hit.records }

        var records: [RawRecord] = []
        collectRecords(from: url, into: &records)
        cacheLock.lock()
        fileCache[url.path] = CacheEntry(mtime: mtime, size: size, records: records)
        cacheLock.unlock()
        return records
    }

    private static func pruneCache(keeping paths: Set<String>) {
        cacheLock.lock()
        fileCache = fileCache.filter { paths.contains($0.key) }
        cacheLock.unlock()
    }

    private static func collectRecords(from url: URL, into records: inout [RawRecord]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        // Walk raw bytes and skip non-assistant lines before paying for JSON parsing.
        let marker = Data("\"assistant\"".utf8)
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            if end > start, data.range(of: marker, in: start..<end) != nil,
               let r = parseRecord(data.subdata(in: start..<end)) {
                records.append(r)
            }
            start = end == data.endIndex ? end : data.index(after: end)
        }
    }

    private static func parseRecord(_ raw: Data) -> RawRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let tsStr = obj["timestamp"] as? String,
              let msg = obj["message"] as? [String: Any],
              let usageDict = msg["usage"] as? [String: Any]
        else { return nil }

        guard let ts = parseDate(tsStr) else { return nil }

        let model = (msg["model"] as? String) ?? "unknown"
        let usage = TokenUsage(
            input: (usageDict["input_tokens"] as? Int) ?? 0,
            output: (usageDict["output_tokens"] as? Int) ?? 0,
            cacheWrite: (usageDict["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheRead: (usageDict["cache_read_input_tokens"] as? Int) ?? 0
        )
        let toolCalls = countToolCalls(msg)
        let cost = calcCost(model: model, usage: usage)

        // Detect rate_limit events from error field and message text
        let errorStr = (obj["error"] as? String) ?? ""
        let msgText = (msg["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let isRateLimit = errorStr == "rate_limit" && msgText.contains("hit your limit")
        let isExtraUsage = errorStr == "rate_limit" && msgText.contains("out of extra usage")

        return RawRecord(timestamp: ts, model: model, usage: usage, toolCalls: toolCalls,
                         cost: cost, isRateLimit: isRateLimit, isExtraUsage: isExtraUsage)
    }

    private static func countToolCalls(_ msg: [String: Any]) -> Int {
        guard let content = msg["content"] as? [[String: Any]] else { return 0 }
        return content.filter { ($0["type"] as? String) == "tool_use" }.count
    }

    // Formatters are expensive to create; reuse them (date(from:) is thread-safe).
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        let iso = s.hasSuffix("Z") ? String(s.dropLast()) + "+00:00" : s
        return isoFrac.date(from: iso) ?? isoPlain.date(from: iso)
    }
}
