import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
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

        // Popover
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let rootView = ContentView().environmentObject(store)
        let hostingController = NSHostingController(rootView: rootView)
        popover.contentViewController = hostingController

        // Apply dark appearance to popover
        popover.appearance = NSAppearance(named: .darkAqua)

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
        statusAnchorObserver = NotificationCenter.default.addObserver(
            forName: .statusItemAnchorDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.alignOpenPopover()
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
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        alignOpenPopover()
        DispatchQueue.main.async { [weak self] in
            self?.alignOpenPopover()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.alignOpenPopover()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func alignOpenPopover() {
        guard
            popover.isShown,
            let button = statusItem.button,
            let buttonWindow = button.window,
            let popoverWindow = popover.contentViewController?.view.window
        else { return }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let popoverFrame = popoverWindow.frame

        let preferredX = buttonRectOnScreen.midX - popoverFrame.width / 2
        let x = min(
            max(preferredX, screenFrame.minX + 8),
            screenFrame.maxX - popoverFrame.width - 8
        )
        let preferredY = buttonRectOnScreen.minY - popoverFrame.height - 4
        let y = min(
            max(preferredY, screenFrame.minY + 8),
            screenFrame.maxY - popoverFrame.height - 8
        )

        popoverWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closePopover() {
        popover.performClose(nil)
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
