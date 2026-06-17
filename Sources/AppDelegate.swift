import AppKit
import SwiftUI

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popupWindow: PopupPanel!
    private var popupHostingController: NSHostingController<AnyView>!
    private var store: ProviderStore!
    private var eventMonitor: Any?
    private var statusAnchorObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupEditMenu()

        store = ProviderStore()

        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        store.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "AI Usage")
            button.image?.size = NSSize(width: 14, height: 14)
            button.title = " —"
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popup
        popupHostingController = NSHostingController(rootView: AnyView(EmptyView()))
        popupWindow = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        popupWindow.contentViewController = popupHostingController
        popupWindow.isReleasedWhenClosed = false
        popupWindow.isOpaque = false
        popupWindow.backgroundColor = .clear
        popupWindow.hasShadow = true
        popupWindow.level = .statusBar
        popupWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
        statusAnchorObserver = NotificationCenter.default.addObserver(
            forName: .statusItemAnchorDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reopenPopover()
        }

        // Start watchers, auth checks, and the fetch scheduler
        store.start()
    }

    // Accessory apps have no menu bar, so standard text shortcuts (Cmd+V/C/X/A) are
    // unwired. Installing an Edit menu routes those key equivalents to the first responder.
    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func togglePopover() {
        if popupWindow.isVisible {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard
            let button = statusItem.button,
            let buttonWindow = button.window
        else { return }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let arrowHeight: CGFloat = 10
        let verticalGap: CGFloat = 4
        let contentWidth = popupContentWidth()
        let idealContentHeight = measuredContentHeight(width: contentWidth)
        let maxWindowHeight = max(220, buttonRectOnScreen.minY - screenFrame.minY - 8)
        let contentHeight = min(idealContentHeight, maxWindowHeight - arrowHeight - verticalGap)
        let windowSize = NSSize(width: contentWidth, height: contentHeight + arrowHeight)

        let preferredX = buttonRectOnScreen.midX - windowSize.width / 2
        let windowX = min(
            max(preferredX, screenFrame.minX + 8),
            screenFrame.maxX - windowSize.width - 8
        )
        let windowY = buttonRectOnScreen.minY - windowSize.height - verticalGap
        let arrowX = buttonRectOnScreen.midX - windowX

        popupHostingController.rootView = AnyView(
            PopupWindowRootView(
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                arrowX: arrowX
            )
            .environmentObject(store)
        )
        popupWindow.setContentSize(windowSize)
        popupWindow.setFrameOrigin(NSPoint(x: windowX, y: windowY))
        popupWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func popupContentWidth() -> CGFloat {
        let visibleIDs = MainActor.assumeIsolated {
            store.visibleProviderIDs
        }
        let showsAntigravity = visibleIDs.contains(.antigravity)
        let hasLeftColumn = visibleIDs.contains { $0 != .antigravity }
        return showsAntigravity && hasLeftColumn ? 640 : 320
    }

    private func measuredContentHeight(width: CGFloat) -> CGFloat {
        let measuringView = NSHostingView(rootView: ContentView().environmentObject(store))
        measuringView.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        measuringView.layoutSubtreeIfNeeded()
        return max(160, ceil(measuringView.fittingSize.height))
    }

    private func reopenPopover() {
        guard popupWindow.isVisible else { return }
        closePopover()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.openPopover()
        }
    }

    private func closePopover() {
        popupWindow.orderOut(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = statusAnchorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension Notification.Name {
    static let statusItemAnchorDidChange = Notification.Name("statusItemAnchorDidChange")
}
