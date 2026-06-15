import Foundation

/// Errors thrown by `ShellProcessRunner`.
enum ShellError: LocalizedError, Equatable {
    case executableNotFound(path: String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut(seconds: TimeInterval)
    case launchFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let p):
            return "Shell executable not found at: \(p)"
        case .nonZeroExit(let code, let stderr):
            return "Process exited with code \(code): \(stderr)"
        case .timedOut(let s):
            return "Process timed out after \(s)s"
        case .launchFailed(let u):
            return "Process launch failed: \(u)"
        }
    }
}
