import Foundation

/// A single shell command to be executed by `ShellProcessRunner`.
struct ShellCommand: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval

    init(executable: String, arguments: [String] = [], timeout: TimeInterval = 10) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }
}
