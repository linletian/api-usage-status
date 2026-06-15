import Foundation

/// Runs a `ShellCommand` and returns its stdout as `Data`.
///
/// All work happens off the actor's serial executor via `Task.detached` for
/// the blocking I/O (`waitUntilExit`, `readDataToEndOfFile`); the actor only
/// orchestrates. A timeout task terminates the process if it overruns.
actor ShellProcessRunner {
    static let shared = ShellProcessRunner()

    func run(_ command: ShellCommand) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(underlying: error.localizedDescription)
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(command.timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        let exitTask = Task.detached { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }
        let stdoutDataTask = Task.detached { () -> Data in
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrDataTask = Task.detached { () -> Data in
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let exitCode = await exitTask.value
        let stdoutData = await stdoutDataTask.value
        let stderrData = await stderrDataTask.value
        timeoutTask.cancel()

        if exitCode != 0 {
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            throw ShellError.nonZeroExit(code: exitCode, stderr: stderrStr)
        }
        return stdoutData
    }
}
