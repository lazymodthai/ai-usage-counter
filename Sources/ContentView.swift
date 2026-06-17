import SwiftUI
import AppKit

// MARK: - Theme
extension Color {
    static let appBg      = Color(red: 0.051, green: 0.051, blue: 0.059) // #0d0d0f
    static let cardBg     = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let divider    = Color.white.opacity(0.07)
    static let accent     = Color(red: 1.0, green: 0.62, blue: 0.0)      // orange
    static let chartPink  = Color(red: 1.0, green: 0.18, blue: 0.33)
    static let opusBlue   = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let sonnetCyan = Color(red: 0.20, green: 0.68, blue: 0.90)
    static let haikuGreen = Color(red: 0.19, green: 0.82, blue: 0.35)

    static func tint(for id: ProviderID) -> Color {
        switch id {
        case .claude: return .accent
        case .codex:  return .haikuGreen
        case .gemini: return .opusBlue
        case .antigravity: return Color(red: 0.70, green: 0.48, blue: 1.0)
        }
    }
}

// MARK: - Root
struct ContentView: View {
    @EnvironmentObject var store: ProviderStore
    let fixedHeight: CGFloat?

    init(fixedHeight: CGFloat? = nil) {
        self.fixedHeight = fixedHeight
    }

    private var leftProviders: [ProviderID] {
        store.visibleProviderIDs.filter { $0 != .antigravity }
    }

    private var visibleColumns: [[ProviderID]] {
        let hasAntigravity = store.visibleProviders.contains(.antigravity)
        if !leftProviders.isEmpty && hasAntigravity {
            return [leftProviders, [.antigravity]]
        }
        if hasAntigravity { return [[.antigravity]] }
        return [leftProviders]
    }

    private var usesTwoColumns: Bool { visibleColumns.count == 2 }
    private var contentWidth: CGFloat { usesTwoColumns ? 640 : 320 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.appBg
            VStack(spacing: 0) {
                HeaderRow()
                Rectangle().fill(Color.divider).frame(height: 1)
                if fixedHeight == nil {
                    columns
                } else {
                    ScrollView(.vertical) {
                        columns
                    }
                    .scrollIndicators(.visible)
                }
                Rectangle().fill(Color.divider).frame(height: 1)
                FooterRow()
            }
        }
        .frame(width: contentWidth)
        .frame(height: fixedHeight, alignment: .top)
        .onAppear { store.refreshAll() }
    }

    @ViewBuilder
    private var columns: some View {
        if usesTwoColumns {
            HStack(alignment: .top, spacing: 0) {
                ProviderColumn(providerIDs: visibleColumns[0])
                    .frame(width: 319)
                Rectangle().fill(Color.divider).frame(width: 1)
                ProviderColumn(providerIDs: visibleColumns[1])
                    .frame(width: 320)
            }
        } else {
            ProviderColumn(providerIDs: visibleColumns.first ?? [])
        }
    }
}

struct PopupWindowRootView: View {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let arrowX: CGFloat

    private let arrowHeight: CGFloat = 10
    private let cornerRadius: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topLeading) {
            PopupChromeShape(arrowX: arrowX, arrowHeight: arrowHeight, cornerRadius: cornerRadius)
                .fill(Color.appBg)
            PopupChromeShape(arrowX: arrowX, arrowHeight: arrowHeight, cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
            ContentView(fixedHeight: contentHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .offset(y: arrowHeight)
        }
        .frame(width: contentWidth, height: contentHeight + arrowHeight)
        .background(Color.clear)
    }
}

struct PopupChromeShape: Shape {
    let arrowX: CGFloat
    let arrowHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let arrowHalfWidth: CGFloat = 10
        let topY = rect.minY + arrowHeight
        let bottomY = rect.maxY
        let leftX = rect.minX
        let rightX = rect.maxX
        let arrowCenterX = min(
            max(arrowX, leftX + cornerRadius + arrowHalfWidth),
            rightX - cornerRadius - arrowHalfWidth
        )

        var path = Path()
        path.move(to: CGPoint(x: leftX + cornerRadius, y: topY))
        path.addLine(to: CGPoint(x: arrowCenterX - arrowHalfWidth, y: topY))
        path.addLine(to: CGPoint(x: arrowCenterX, y: rect.minY))
        path.addLine(to: CGPoint(x: arrowCenterX + arrowHalfWidth, y: topY))
        path.addLine(to: CGPoint(x: rightX - cornerRadius, y: topY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: topY + cornerRadius),
            control: CGPoint(x: rightX, y: topY)
        )
        path.addLine(to: CGPoint(x: rightX, y: bottomY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rightX - cornerRadius, y: bottomY),
            control: CGPoint(x: rightX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: leftX + cornerRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: leftX, y: bottomY - cornerRadius),
            control: CGPoint(x: leftX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: leftX, y: topY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftX + cornerRadius, y: topY),
            control: CGPoint(x: leftX, y: topY)
        )
        path.closeSubpath()
        return path
    }
}

struct ProviderColumn: View {
    let providerIDs: [ProviderID]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(providerIDs.enumerated()), id: \.element.id) { index, id in
                ProviderSection(providerID: id)
                if index < providerIDs.count - 1 {
                    Rectangle().fill(Color.divider).frame(height: 1)
                }
            }
        }
    }
}

// MARK: - Header
struct HeaderRow: View {
    @EnvironmentObject var store: ProviderStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: store.menubarSource.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.tint(for: store.menubarSource))
            Text("AI Usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if store.isLoading {
                ProgressView().scaleEffect(0.55).tint(Color.white.opacity(0.5))
            }
            Button(action: { store.refreshAll() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            Button(action: { store.showSettings.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $store.showSettings) {
                SettingsView().environmentObject(store)
            }
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Quit AI Usage Counter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Provider Section
struct ProviderSection: View {
    @EnvironmentObject var store: ProviderStore
    let providerID: ProviderID

    private var authState: AuthState { store.authStates[providerID] ?? .signedOut }
    private var isConnected: Bool { authState == .signedIn }
    private var hasBars: Bool { isConnected || providerID == .claude }
    private var isOnMenubar: Bool { store.menubarSource == providerID }
    private var quotaBars: [(lane: ProviderQuotaLane, vm: UsageBarVM)] {
        store.quotaBars(for: providerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider header row
            HStack(spacing: 6) {
                Image(systemName: providerID.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tint(for: providerID))
                Text(providerID.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if (providerID == .gemini || providerID == .antigravity) && isConnected {
                    Text("beta")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                if providerID == .claude && store.claudeUsingLocal {
                    Text("local estimate")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                if authState == .expired {
                    Text("session expired")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.yellow.opacity(0.9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.12))
                        .cornerRadius(3)
                }
                Spacer()
                if hasBars {
                    MenubarToggle(providerID: providerID, isOn: isOnMenubar)
                }
                if !isConnected {
                    Button(action: { store.presentLogin(providerID) }) {
                        Text(authState == .expired ? "Re-sign in" : "Sign in")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.tint(for: providerID))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.cardBg)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }

            if hasBars {
                if let vm = store.sessionBar(for: providerID) {
                    UsageBarRow(
                        label: "Current Session", icon: "clock.fill",
                        iconColor: Color.tint(for: providerID), vm: vm)
                }
                if let vm = store.weeklyBar(for: providerID) {
                    UsageBarRow(
                        label: "Weekly", icon: "calendar",
                        iconColor: .sonnetCyan, vm: vm)
                }
                ForEach(quotaBars, id: \.lane.id) { item in
                    UsageBarRow(
                        label: item.lane.label,
                        icon: "gauge.with.dots.needle.bottom.50percent",
                        iconColor: Color.tint(for: providerID),
                        vm: item.vm)
                }
                if providerID != .claude
                    && store.usages[providerID] == nil
                    && authState == .signedIn {
                    ProviderFetchStatusRow(providerID: providerID)
                }
            } else if authState == .signedOut {
                Text("Not connected")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct ProviderFetchStatusRow: View {
    @EnvironmentObject var store: ProviderStore
    let providerID: ProviderID

    private var isFetching: Bool { store.fetchingProviders.contains(providerID) }
    private var failureCount: Int { store.fetchFailures[providerID] ?? 0 }

    var body: some View {
        HStack(spacing: 6) {
            if isFetching {
                ProgressView().scaleEffect(0.55).tint(Color.white.opacity(0.5))
            } else if failureCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.yellow.opacity(0.75))
            }
            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.35))
        }
    }

    private var statusText: String {
        if isFetching { return "Fetching usage..." }
        if failureCount > 0 { return "Usage not found. Retrying..." }
        return "Waiting to fetch usage..."
    }
}

// Small "menu bar" pill — filled when this provider drives the menu bar,
// clickable to switch.
struct MenubarToggle: View {
    @EnvironmentObject var store: ProviderStore
    let providerID: ProviderID
    let isOn: Bool

    var body: some View {
        Button(action: { store.menubarSource = providerID }) {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "menubar.arrow.up.rectangle" : "rectangle.dashed")
                    .font(.system(size: 8))
                Text("menu bar")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(isOn ? Color.tint(for: providerID) : Color.white.opacity(0.35))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((isOn ? Color.tint(for: providerID) : Color.white).opacity(0.08))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(isOn)
        .help("Show \(providerID.displayName) on the menu bar")
    }
}

// MARK: - Footer
struct FooterRow: View {
    @EnvironmentObject var store: ProviderStore

    private var updatedAt: Date {
        store.usages[store.menubarSource]?.fetchedAt ?? store.data.lastUpdated
    }
    private var isLive: Bool {
        store.authStates[store.menubarSource] == .signedIn
            && store.usages[store.menubarSource] != nil
    }

    var body: some View {
        HStack(spacing: 4) {
            if isLive {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.haikuGreen)
                Text("Live · \(store.menubarSource.displayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.haikuGreen.opacity(0.8))
                Text("·")
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            Text("Updated \(updatedAt.formatted(.dateTime.hour().minute().second()))")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.3))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Usage Bar Row
struct UsageBarRow: View {
    let label: String
    let icon: String
    let iconColor: Color
    let vm: UsageBarVM

    private var pct: Double { vm.fraction * 100 }
    private var barColor: Color {
        if vm.fraction >= 1.0 { return .red }
        if vm.fraction >= 0.9 { return .orange }
        if vm.fraction >= 0.7 { return Color(red: 1, green: 0.75, blue: 0) }
        return .accent
    }

    // If `usedText` already contains a %, just show it — otherwise "used / limit tokens"
    private var infoText: String {
        if vm.usedText.contains("%") { return "" }
        if vm.limitText.isEmpty { return vm.usedText }
        return "\(vm.usedText) / \(vm.limitText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                Spacer()
                if vm.isActive && vm.fraction > 0 {
                    Text(String(format: "%.2f%%", pct))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(barColor)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.9), barColor],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(1, max(0, vm.fraction)))
                        .animation(.easeOut(duration: 0.5), value: vm.fraction)
                }
            }
            .frame(height: 8)
            .cornerRadius(4)

            HStack {
                Text(infoText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                Spacer()
                Text(vm.resetLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(barColor.opacity(0.8))
            }
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var store: ProviderStore
    @Environment(\.dismiss) private var dismiss

    @State private var sessionLimitText = ""
    @State private var weeklyLimitText = ""
    @State private var intervalText = ""

    private let proSessionLimit  = 8_800_000
    private let proWeeklyLimit   = 88_000_000
    private let maxSessionLimit  = 44_000_000
    private let maxWeeklyLimit   = 440_000_000

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Done") { applySettings(); dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Rectangle().fill(Color.divider).frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Accounts
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Accounts", systemImage: "person.2")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))

                            ForEach(ProviderID.allCases) { id in
                                ProviderAccountRow(providerID: id)
                            }
                        }

                        Rectangle().fill(Color.divider).frame(height: 1)

                        // Visible agents
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Visible Agents", systemImage: "eye")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))

                            ForEach(ProviderID.allCases) { id in
                                VisibleProviderRow(providerID: id)
                            }
                        }

                        Rectangle().fill(Color.divider).frame(height: 1)

                        // Menu bar source
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Menu Bar Shows", systemImage: "menubar.rectangle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))

                            Picker("", selection: $store.menubarSource) {
                                ForEach(menubarChoices) { id in
                                    Text(id.displayName).tag(id)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("เลือกได้เฉพาะ provider ที่เชื่อมต่อแล้ว")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }

                        Rectangle().fill(Color.divider).frame(height: 1)

                        // Refresh
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Refresh Interval", systemImage: "clock")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))
                            SettingField(label: "Interval (seconds, min 30)", placeholder: "60", text: $intervalText)
                        }

                        Rectangle().fill(Color.divider).frame(height: 1)

                        // Claude local fallback limits
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Claude Local Fallback", systemImage: "internaldrive")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))

                            Text("ใช้เมื่อยังไม่ได้ login claude.ai — ประมาณจากไฟล์ Claude Code (0 = ตรวจอัตโนมัติ)")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.35))
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                PlanPresetButton(label: "Pro", sublabel: "8.8M / 88M") {
                                    sessionLimitText = "\(proSessionLimit)"
                                    weeklyLimitText  = "\(proWeeklyLimit)"
                                }
                                PlanPresetButton(label: "Max 5×", sublabel: "44M / 440M") {
                                    sessionLimitText = "\(maxSessionLimit)"
                                    weeklyLimitText  = "\(maxWeeklyLimit)"
                                }
                                PlanPresetButton(label: "Auto", sublabel: "detect") {
                                    sessionLimitText = "0"
                                    weeklyLimitText  = "0"
                                }
                            }

                            SettingField(label: "Session limit (5h block)", placeholder: "0", text: $sessionLimitText)
                            SettingField(label: "Weekly limit", placeholder: "0", text: $weeklyLimitText)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 280, height: 480)
        .onAppear {
            sessionLimitText = "\(store.sessionTokenLimit)"
            weeklyLimitText  = "\(store.weeklyTokenLimit)"
            intervalText     = String(Int(store.refreshInterval))
        }
    }

    private var menubarChoices: [ProviderID] {
        var choices = store.visibleConnectedProviders
        if choices.isEmpty, store.isProviderVisible(.claude) { choices = [.claude] }
        if choices.isEmpty { choices = store.visibleProviderIDs }
        if !choices.contains(store.menubarSource) { choices.append(store.menubarSource) }
        return choices
    }

    private func applySettings() {
        if let v = Int(sessionLimitText), v >= 0 { store.sessionTokenLimit = v }
        if let v = Int(weeklyLimitText),  v >= 0 { store.weeklyTokenLimit  = v }
        if let v = Double(intervalText),  v >= 30 { store.refreshInterval = v }
    }
}

struct ProviderAccountRow: View {
    @EnvironmentObject var store: ProviderStore
    let providerID: ProviderID

    private var authState: AuthState { store.authStates[providerID] ?? .signedOut }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: providerID.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tint(for: providerID))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(providerID.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.system(size: 9))
                    .foregroundStyle(statusColor)
            }
            Spacer()
            if authState == .signedIn {
                Button(action: { store.signOut(providerID) }) {
                    Text("Sign out")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.cardBg)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { store.presentLogin(providerID) }) {
                    Text(authState == .expired ? "Re-sign in" : "Sign in")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.tint(for: providerID))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.cardBg)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
    }

    private var statusText: String {
        switch authState {
        case .signedIn:  return "Connected"
        case .expired:   return "Session expired"
        case .signedOut: return "Not connected"
        }
    }

    private var statusColor: Color {
        switch authState {
        case .signedIn:  return .haikuGreen
        case .expired:   return .yellow
        case .signedOut: return Color.white.opacity(0.35)
        }
    }
}

struct VisibleProviderRow: View {
    @EnvironmentObject var store: ProviderStore
    let providerID: ProviderID

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.isProviderVisible(providerID) },
            set: { store.setProviderVisible(providerID, visible: $0) }
        )) {
            HStack(spacing: 7) {
                Image(systemName: providerID.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tint(for: providerID))
                    .frame(width: 14)
                Text(providerID.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                if providerID == .antigravity {
                    Text("right column")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(store.visibleProviderIDs.count == 1 && store.isProviderVisible(providerID))
    }
}

struct PlanPresetButton: View {
    let label: String
    let sublabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(sublabel)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.cardBg)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SettingField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.cardBg)
                .cornerRadius(6)
        }
    }
}
