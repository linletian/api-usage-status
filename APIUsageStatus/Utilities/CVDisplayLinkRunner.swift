import Foundation
import CoreVideo

/// Wraps a `CVDisplayLink` to deliver a periodic callback on the main actor.
///
/// The C callback runs on the display-link thread; it dispatches to
/// `DispatchQueue.main.async` so that the `@MainActor` closure is safely
/// invoked on the main queue.  Use `CVDisplayLinkRunner` instead of
/// `CADisplayLink` to stay compatible with macOS 13.
final class CVDisplayLinkRunner: @unchecked Sendable {
    private var displayLink: CVDisplayLink?
    private let callback: @MainActor () -> Void

    /// Creates a display-link runner, or `nil` if the system cannot create
    /// the underlying `CVDisplayLink`.
    init?(callback: @escaping @MainActor () -> Void) {
        self.callback = callback

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link = link else {
            return nil
        }
        self.displayLink = link

        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (
            _ displayLink: CVDisplayLink,
            _ inNow: UnsafePointer<CVTimeStamp>,
            _ inOutputTime: UnsafePointer<CVTimeStamp>,
            _ flagsIn: CVOptionFlags,
            _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
            _ context: UnsafeMutableRawPointer?
        ) -> CVReturn in
            guard let context = context else { return kCVReturnError }
            let runner = Unmanaged<CVDisplayLinkRunner>
                .fromOpaque(context)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                runner.callback()
            }
            return kCVReturnSuccess
        }, context)
    }

    /// Starts the display link.  No-op if already running or creation failed.
    func start() {
        guard let link = displayLink else { return }
        CVDisplayLinkStart(link)
    }

    /// Stops the display link.
    func stop() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
    }

    /// Whether the display link is currently running.
    var isRunning: Bool {
        guard let link = displayLink else { return false }
        return CVDisplayLinkIsRunning(link)
    }

    deinit {
        stop()
        displayLink = nil
    }
}
