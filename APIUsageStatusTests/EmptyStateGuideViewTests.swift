import XCTest
import SwiftUI
import AppKit
@testable import APIUsageStatus

/// Tests for `EmptyStateGuideView`.
///
/// The view is a leaf SwiftUI component, so the tests render it through an
/// `NSHostingController` to obtain a real view hierarchy. We then walk the
/// hierarchy to verify the three textual elements (title / subtitle / button
/// label) are present, and we trigger the button to confirm the
/// `onAddInstance` closure is wired through unchanged.
@MainActor
final class EmptyStateGuideViewTests: XCTestCase {

    // MARK: - Rendering

    /// The hero title "No Instances Configured" must be rendered verbatim.
    /// This is the contract that drives the empty-state messaging across the
    /// popover / settings surface.
    func testRendersTitle() {
        let view = EmptyStateGuideView(onAddInstance: {})
        let host = NSHostingController(rootView: view)
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "No Instances Configured"
            },
            "Expected the title 'No Instances Configured' to appear in the view hierarchy"
        )
    }

    /// The subtitle must explain what the user can do next. The wording is
    /// part of the product spec, so it must not regress silently.
    func testRendersSubtitle() {
        let view = EmptyStateGuideView(onAddInstance: {})
        let host = NSHostingController(rootView: view)
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "Add your first API instance to start monitoring usage"
            },
            "Expected the subtitle text to appear in the view hierarchy"
        )
    }

    /// The CTA button must show the exact product-approved label.
    /// Changing this string is a product-level change, not a refactor.
    func testRendersButtonLabel() {
        let view = EmptyStateGuideView(onAddInstance: {})
        let host = NSHostingController(rootView: view)
        host.loadView()

        XCTAssertTrue(
            Self.hierarchy(of: host.view) { text in
                text == "Add Your First Instance"
            },
            "Expected the button label 'Add Your First Instance' to appear in the view hierarchy"
        )
    }

    /// Tapping the CTA must invoke the `onAddInstance` closure exactly once.
    /// This is the user-facing contract that the empty state exists to
    /// enforce — a broken wiring here would strand the user with no way to
    /// add an instance from this surface.
    func testTappingButtonInvokesOnAddInstance() {
        var callCount = 0
        let view = EmptyStateGuideView(onAddInstance: { callCount += 1 })

        // Drive the SwiftUI view via AppKit: SwiftUI's `Button` is
        // bridged to `NSButton` under `NSHostingController`, so
        // `performClick` fires the closure the view was given.
        let host = NSHostingController(rootView: view)
        host.loadView()
        host.view.layoutSubtreeIfNeeded()

        guard let button = Self.firstButton(in: host.view) else {
            XCTFail("Expected the empty-state view to contain an NSButton for the CTA")
            return
        }

        button.performClick(nil)

        XCTAssertEqual(
            callCount,
            1,
            "Tapping the CTA must invoke onAddInstance exactly once"
        )
    }

    // MARK: - Helpers

    /// Recursively walks an `NSView` subtree collecting every `NSTextField`
    /// string value, and returns `true` as soon as any of them satisfies
    /// `predicate`. SwiftUI's `Text` is bridged to `NSTextField` inside an
    /// `NSHostingController`, so this is a stable introspection path.
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

    /// Returns the first `NSButton` reachable from `view` via a depth-first
    /// walk. SwiftUI's `Button` is bridged to `NSButton` by AppKit, so the
    /// CTA on `EmptyStateGuideView` is reachable through this path.
    private static func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton {
            return button
        }
        for subview in view.subviews {
            if let button = firstButton(in: subview) {
                return button
            }
        }
        return nil
    }
}
