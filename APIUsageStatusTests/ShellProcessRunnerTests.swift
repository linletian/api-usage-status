import XCTest
@testable import APIUsageStatus

final class ShellProcessRunnerTests: XCTestCase {
    let runner = ShellProcessRunner.shared

    func testSuccess() async throws {
        let cmd = ShellCommand(executable: "/bin/echo", arguments: ["hello"])
        let data = try await runner.run(cmd)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello\n")
    }

    func testExecutableNotFound() async {
        let cmd = ShellCommand(executable: "/nonexistent/path/foo", arguments: [])
        do {
            _ = try await runner.run(cmd)
            XCTFail("expected throw")
        } catch {
            // Process.run() throws CocoaError for missing executables on macOS;
            // we wrap it as .launchFailed. Either way we expect to throw.
        }
    }

    func testNonZeroExit() async {
        let cmd = ShellCommand(
            executable: "/bin/sh",
            arguments: ["-c", "echo oops >&2; exit 7"]
        )
        do {
            _ = try await runner.run(cmd)
            XCTFail("expected throw")
        } catch let error as ShellError {
            if case .nonZeroExit(let code, let stderr) = error {
                XCTAssertEqual(code, 7)
                XCTAssertTrue(stderr.contains("oops"))
            } else {
                XCTFail("expected nonZeroExit, got \(error)")
            }
        } catch {
            XCTFail("expected ShellError, got \(error)")
        }
    }

    func testTimeout() async {
        let cmd = ShellCommand(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.5
        )
        do {
            _ = try await runner.run(cmd)
            XCTFail("expected timeout")
        } catch {
            // Process gets terminated; on macOS the child of a terminated
            // sleep exits with a non-zero status (SIGTERM). Either timedOut
            // or nonZeroExit is acceptable — we just want the runner to
            // surface the failure rather than hang.
        }
    }
}
