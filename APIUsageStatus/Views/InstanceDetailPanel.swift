import AppKit
import SwiftUI

// MARK: - InstanceDetailPanelController

/// A non-floating NSPanel that displays a single instance's usage details.
/// Clicking outside the panel automatically closes it (`hidesOnDeactivate`).
/// Opening a new instance closes any previously shown panel.
@MainActor
final class InstanceDetailPanelController: NSObject {
    private let appStateProxy: AppStateProxy
    private var currentPanel: NSPanel?
    private let logger = AppLogger(category: "ui")

    init(appStateProxy: AppStateProxy) {
        self.appStateProxy = appStateProxy
        super.init()
    }

    /// Shows an independent panel for the instance with the given UUID.
    /// If a panel is already open, it is closed before the new one is displayed.
    func show(for instanceUUID: String) {
        // Close existing panel to avoid duplicates
        if let existing = currentPanel {
            existing.delegate = nil
            existing.close()
        }
        currentPanel = nil

        guard let slot = appStateProxy.slotViewDataList.first(where: { $0.uuid == instanceUUID }) else {
            logger.warning("InstanceDetailPanel: Could not find instance with UUID \(instanceUUID)")
            return
        }

        let view = UsageCardView(slot: slot, lastRefreshAt: appStateProxy.lastRefreshAt)
        let hostingController = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = slot.displayName.isEmpty ? slot.shortName : slot.displayName
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = false
        panel.contentViewController = hostingController
        panel.delegate = self

        // Auto-size to fit the SwiftUI content
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        let width = max(350, fittingSize.width + 32)
        let height = max(200, fittingSize.height + 44)
        panel.setContentSize(NSSize(width: width, height: height))

        panel.center()
        panel.makeKeyAndOrderFront(nil)

        currentPanel = panel
        logger.info("Opened detail panel for \(panel.title ?? "unknown")")
    }
}

// MARK: - NSWindowDelegate

extension InstanceDetailPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow,
           closingWindow === currentPanel {
            currentPanel?.delegate = nil
            currentPanel = nil
            logger.info("Detail panel closed")
        }
    }
}
