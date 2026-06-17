import XCTest
import SwiftUI
import AppKit
@testable import APIUsageStatus

/// Tests for `InstanceCardView`.
///
/// The view is a leaf SwiftUI component rendered through an `NSHostingController`.
/// We walk the view hierarchy to verify the seven expected UI elements are present,
/// and we trigger the edit/delete buttons to confirm their callbacks fire.
@MainActor
final class InstanceCardViewTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeInstance(
        displayName: String = "Test Instance",
        shortName: String = "TI",
        provider: String = "minimax",
        dimension: String = "general",
        trackingEnabled: Bool = true
    ) -> Instance {
        Instance(
            provider: provider,
            dimension: dimension,
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: "test-key-ref",
            enabled: trackingEnabled,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
    }

    // MARK: - Rendering: all 7 UI elements

    /// 1. The display name must render. When `displayName` is empty, it falls
    ///    back to "Untitled".
    func testRendersDisplayName() {
        let instance = makeInstance(displayName: "My API")
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "My API"
            },
            "Expected the display name 'My API' to appear in the view hierarchy"
        )
    }

    /// 1b. When `displayName` is empty, the view must show "Untitled".
    func testRendersUntitledWhenDisplayNameEmpty() {
        let instance = makeInstance(displayName: "")
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "Untitled"
            },
            "Expected 'Untitled' to appear when displayName is empty"
        )
    }

    /// 2. The subtitle must show "Provider · dimension".
    func testRendersSubtitle() {
        let instance = makeInstance(provider: "minimax", dimension: "general")
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "MiniMax · general"
            },
            "Expected subtitle 'MiniMax · general' to appear in the view hierarchy"
        )
    }

    /// 3. The shortName badge must render the instance's shortName.
    func testRendersShortNameBadge() {
        let instance = makeInstance(shortName: "TI")
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "TI"
            },
            "Expected the shortName badge 'TI' to appear in the view hierarchy"
        )
    }

    /// 4. The tracking toggle must be present (SwiftUI Toggle is bridged to
    ///    NSSwitch under NSHostingController).
    func testRendersTrackingToggle() {
        let instance = makeInstance(trackingEnabled: true)
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()
        host.view.layoutSubtreeIfNeeded()

        // SwiftUI Toggle bridges to NSSwitch in AppKit hosting
        let hasSwitch = Self.findSwitch(in: host.view)
        XCTAssertTrue(hasSwitch, "Expected an NSSwitch for the tracking toggle")
    }

    /// 5. The edit button (pencil icon) must be present as an NSButton.
    func testRendersEditButton() {
        let instance = makeInstance()
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()
        host.view.layoutSubtreeIfNeeded()

        // The edit button is one of potentially several buttons; we verify
        // that at least two buttons exist (edit + delete).
        let buttons = Self.allButtons(in: host.view)
        XCTAssertGreaterThanOrEqual(
            buttons.count, 2,
            "Expected at least 2 buttons (edit + delete) in the view hierarchy"
        )
    }

    /// 6. The delete button (trash icon) must be present as an NSButton.
    func testRendersDeleteButton() {
        let instance = makeInstance()
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()
        host.view.layoutSubtreeIfNeeded()

        let buttons = Self.allButtons(in: host.view)
        XCTAssertGreaterThanOrEqual(
            buttons.count, 2,
            "Expected at least 2 buttons (edit + delete) in the view hierarchy"
        )
    }

    // MARK: - Callbacks

    /// Tapping the edit button must invoke `onEdit` exactly once.
    func testEditCallbackFires() {
        var editCallCount = 0
        let instance = makeInstance()
        let view = InstanceCardView(
            instance: instance,
            isExpanded: false,
            onEdit: { editCallCount += 1 },
            onDelete: {},
            onToggleTracking: {},
            onToggleExpand: {}
        )
        let host = NSHostingController(rootView: view)
        host.loadView()
        host.view.layoutSubtreeIfNeeded()

        // Find the button whose accessibility label or position corresponds to
        // the edit (pencil) action. Since both buttons are borderless, we
        // click the first actionable button that is NOT the delete button.
        // We identify by order: edit comes before delete in the HStack.
        let buttons = Self.allButtons(in: host.view)
        guard buttons.count >= 2 else {
            XCTFail("Expected at least 2 buttons (edit + delete)")
            return
        }

        // The edit button is the first of the two action buttons.
        // SwiftUI HStack renders left-to-right, so pencil (edit) comes first.
        buttons[0].performClick(nil)

        XCTAssertEqual(
            editCallCount, 1,
            "Tapping the edit button must invoke onEdit exactly once"
        )
    }

    /// Tapping the delete button must invoke `onDelete` exactly once.
    func testDeleteCallbackFires() {
        var deleteCallCount = 0
        let instance = makeInstance()
        let view = InstanceCardView(
            instance: instance,
            isExpanded: false,
            onEdit: {},
            onDelete: { deleteCallCount += 1 },
            onToggleTracking: {},
            onToggleExpand: {}
        )
        let host = NSHostingController(rootView: view)
        host.loadView()
        host.view.layoutSubtreeIfNeeded()

        let buttons = Self.allButtons(in: host.view)
        guard buttons.count >= 2 else {
            XCTFail("Expected at least 2 buttons (edit + delete)")
            return
        }

        // The delete button is the second of the two action buttons.
        buttons[1].performClick(nil)

        XCTAssertEqual(
            deleteCallCount, 1,
            "Tapping the delete button must invoke onDelete exactly once"
        )
    }

    // MARK: - Provider display name mapping

    /// The subtitle must use `Provider.displayName` for known providers.
    func testSubtitleUsesProviderDisplayName() {
        let instance = makeInstance(provider: "deepseek", dimension: "balance")
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "DeepSeek · balance"
            },
            "Expected 'DeepSeek · balance' for provider=deepseek"
        )
    }

    /// Unknown providers fall back to `.capitalized`.
    func testSubtitleCapitalizesUnknownProvider() {
        let instance = makeInstance(provider: "somecloud", dimension: "usage")
        let host = NSHostingController(rootView: testView(instance: instance))
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "Somecloud · usage"
            },
            "Expected 'Somecloud · usage' for unknown provider"
        )
    }

    // MARK: - Helpers

    private func testView(instance: Instance) -> some View {
        InstanceCardView(
            instance: instance,
            isExpanded: false,
            onEdit: {},
            onDelete: {},
            onToggleTracking: {},
            onToggleExpand: {}
        )
        .frame(width: 500, height: 60)
    }

    /// Recursively walks an `NSView` subtree collecting every `NSTextField`
    /// string value, and returns `true` as soon as any of them satisfies
    /// `predicate`.
    private static func hierarchy(
        of view: NSView,
        matching predicate: (String) -> Bool
    ) -> Bool {
        if let textField = view as? NSTextField, predicate(textField.stringValue) {
            return true
        }
        for subview in view.subviews where hierarchy(of: subview, matching: predicate) {
            return true
        }
        return false
    }

    /// Returns all `NSButton` instances reachable from `view` via depth-first walk.
    private static func allButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let button = view as? NSButton {
            result.append(button)
        }
        for subview in view.subviews {
            result.append(contentsOf: allButtons(in: subview))
        }
        return result
    }

    /// Returns `true` if any `NSSwitch` is found in the view hierarchy.
    private static func findSwitch(in view: NSView) -> Bool {
        if view is NSSwitch { return true }
        return view.subviews.contains(where: { findSwitch(in: $0) })
    }
}