import XCTest
@testable import APIUsageStatus

final class OpenCodeWorkspaceResolverTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("opencode-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        OpenCodeWorkspaceResolver.testDirectoryOverride = tmpDir.path
        OpenCodeWorkspaceResolver.grepPath = "/usr/bin/grep"
        OpenCodeWorkspaceResolver.scanTimeout = 5
        OpenCodeWorkspaceResolver.clearCache()
    }

    override func tearDownWithError() throws {
        OpenCodeWorkspaceResolver.testDirectoryOverride = nil
        OpenCodeWorkspaceResolver.grepPath = "/usr/bin/grep"
        OpenCodeWorkspaceResolver.scanTimeout = 5
        OpenCodeWorkspaceResolver.clearCache()
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    func testReturnsNilWhenDirectoryEmpty() {
        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
        XCTAssertNil(UserDefaults.standard.string(forKey: "opencode.workspaceID"))
    }

    func testReturnsNilWhenLogsHaveNoWorkspaceURL() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        INFO 2026-06-18T10:00:00 service=llm providerID=opencode-go modelID=glm-5.1
        """)
        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
        XCTAssertNil(UserDefaults.standard.string(forKey: "opencode.workspaceID"))
    }

    func testExtractsWorkspaceIDFromLogAndCachesIt() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        INFO 2026-06-18T10:00:00 service=llm info message without URL
        ERROR 2026-06-18T10:30:15 service=session.processor error=Insufficient balance. Manage your billing here: https://opencode.ai/workspace/wrk_01ABCDEFGHIJKLMNOPQRSTUVWX/billing stack=...
        """)

        XCTAssertEqual(OpenCodeWorkspaceResolver.resolveWorkspaceID(),
                       "wrk_01ABCDEFGHIJKLMNOPQRSTUVWX")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "opencode.workspaceID"),
                       "wrk_01ABCDEFGHIJKLMNOPQRSTUVWX")
    }

    func testCachedValueIsReturnedWithoutRescanning() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_FIRSTIDSPACEIDSPACEIDSPACED/billing
        """)
        XCTAssertEqual(OpenCodeWorkspaceResolver.resolveWorkspaceID(),
                       "wrk_FIRSTIDSPACEIDSPACEIDSPACED")

        // Add a new log with a different ID. With the cache populated, the
        // resolver must NOT touch the new file — it should keep returning the
        // first one observed.
        try writeLog(name: "opencode-2026-06-19.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_NEWIDNEWIDNEWIDNEWIDNEW/billing
        """)
        XCTAssertEqual(OpenCodeWorkspaceResolver.resolveWorkspaceID(),
                       "wrk_FIRSTIDSPACEIDSPACEIDSPACED")
    }

    func testClearCacheRemovesCachedValue() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_AAAAAAAABBBBBBBBCCCCCCCC/billing
        """)
        XCTAssertEqual(OpenCodeWorkspaceResolver.resolveWorkspaceID(),
                       "wrk_AAAAAAAABBBBBBBBCCCCCCCC")
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "opencode.workspaceID"))

        OpenCodeWorkspaceResolver.clearCache()
        XCTAssertNil(UserDefaults.standard.string(forKey: "opencode.workspaceID"))
    }

    func testNonLogFilesAreIgnored() throws {
        // Same URL but in a .txt file — must not be picked up.
        try writeFile(name: "notes.txt", contents: """
        see https://opencode.ai/workspace/wrk_SHOULDNOTBESEEN0000000000/billing
        """)
        try writeLog(name: "opencode-2026-06-18.log", contents: "no URL here\n")
        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
    }

    func testMultipleLogsReturnAnID() throws {
        // `scanLogs` sorts log file names before processing, so the earliest
        // (lexicographically smallest) name wins. Here `opencode-2026-06-17.log`
        // sorts before `opencode-2026-06-18.log`, so its ID is what the
        // resolver should return.
        try writeLog(name: "opencode-2026-06-17.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_AAAWORKSPACEIDWORK00AAA/billing
        """)
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_ZZZWORKSPACEIDWORK00ZZZ/billing
        """)
        XCTAssertEqual(OpenCodeWorkspaceResolver.resolveWorkspaceID(),
                       "wrk_AAAWORKSPACEIDWORK00AAA")
    }

    func testCachedWorkspaceIDReturnsNilWhenEmpty() {
        XCTAssertNil(OpenCodeWorkspaceResolver.cachedWorkspaceID())
    }

    func testCachedWorkspaceIDDoesNotScan() throws {
        // No log files at all — `cachedWorkspaceID` must not fall back to a
        // scan, even when the cache is empty.
        XCTAssertNil(OpenCodeWorkspaceResolver.cachedWorkspaceID())

        // Now drop a matching log file but do NOT call resolve. cachedWorkspaceID
        // must still return nil because the scan only happens via resolve/prewarm.
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_CACHEDCHECK0000000000/billing
        """)
        XCTAssertNil(OpenCodeWorkspaceResolver.cachedWorkspaceID(),
                     "cachedWorkspaceID must not trigger log scanning")
    }

    func testCachedWorkspaceIDReturnsSeededValue() {
        UserDefaults.standard.set("wrk_SEEDEDVALUE0000000000",
                                  forKey: "opencode.workspaceID")
        XCTAssertEqual(OpenCodeWorkspaceResolver.cachedWorkspaceID(),
                       "wrk_SEEDEDVALUE0000000000")
    }

    func testPrewarmPopulatesCache() async throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_PREWARMEDVALUE0000000/billing
        """)
        XCTAssertNil(OpenCodeWorkspaceResolver.cachedWorkspaceID())

        OpenCodeWorkspaceResolver.prewarm()

        // Poll briefly for the background task to write to UserDefaults.
        // The scan is fast on small files; 2s is plenty.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if OpenCodeWorkspaceResolver.cachedWorkspaceID() != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(OpenCodeWorkspaceResolver.cachedWorkspaceID(),
                       "wrk_PREWARMEDVALUE0000000")
    }

    // MARK: - Format contract

    /// Verifies the canonical wrk_ format passes the regex. If OpenCode's
    /// character set ever drifts (e.g. mixed case), this is the canary that
    /// fails first; the matching `assert` in `validateFormatContract` then
    /// surfaces the regression at dev launch.
    func testRegexAcceptsCanonicalUppercaseID() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_01ABCDEFGHIJKLMNOPQRSTUVWX/billing
        """)
        XCTAssertEqual(OpenCodeWorkspaceResolver.resolveWorkspaceID(),
                       "wrk_01ABCDEFGHIJKLMNOPQRSTUVWX")
    }

    /// Lowercase chars in the ID segment are not part of the current
    /// contract. This test pins that boundary: if OpenCode ever switches to
    /// mixed case, this test must be updated alongside the regex.
    func testRegexRejectsLowercaseID() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_01kh8jn2c5qnn00v7n459psjb2/billing
        """)
        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
    }

    /// Mixed-case IDs are also out of contract. Same intent as above.
    func testRegexRejectsMixedCaseID() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_01Kh8Jn2C5QNN00V7N459PSJB2/billing
        """)
        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
    }

    /// Non-alphanumeric chars (hyphens, underscores) inside the ID segment
    /// are out of contract.
    func testRegexRejectsNonAlphanumericID() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_01KH8-JN2C-5QNN-00V7-N459PSJB2/billing
        """)
        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
    }

    /// Trailing junk after a valid ID (e.g. an extra char before `/`) must
    /// not extend the match. Grep's `-o` output is line-scoped, so this
    /// tests the post-grep regex extraction in Swift.
    func testRegexStopsAtNonAlphanumeric() throws {
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_SHORT00ABC/billing
        """)
        XCTAssertEqual(OpenCodeWorkspaceResolver.resolveWorkspaceID(),
                       "wrk_SHORT00ABC")
    }

    // MARK: - scanLogs error paths

    /// Pointing the override at a regular file (not a directory) makes
    /// `contentsOfDirectory` throw "not a directory". The catch branch should
    /// log a warning and return nil.
    func testScanReturnsNilWhenContentsOfDirectoryFails() throws {
        let filePath = tmpDir.appendingPathComponent("not-a-dir").path
        try Data().write(to: URL(fileURLWithPath: filePath))
        OpenCodeWorkspaceResolver.testDirectoryOverride = filePath

        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
        XCTAssertNil(UserDefaults.standard.string(forKey: "opencode.workspaceID"))
    }

    /// `Process.run()` throws if the executable is missing or not executable.
    /// Override the path to a nonexistent location and verify the resolver
    /// swallows the error and returns nil rather than propagating.
    func testScanReturnsNilWhenGrepBinaryMissing() throws {
        OpenCodeWorkspaceResolver.grepPath = "/nonexistent/path/grep-binary-\(UUID().uuidString)"
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_GREPMISSING00000000/billing
        """)

        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
        XCTAssertNil(UserDefaults.standard.string(forKey: "opencode.workspaceID"))
    }

    /// Tighter timeout + a fake grep that blocks longer than the timeout
    /// exercises the `process.terminate()` branch. We verify the resolver
    /// returns nil within a sane wall-clock bound (well below the fake
    /// grep's 10s sleep) and that the cache stays empty.
    func testScanReturnsNilOnTimeout() throws {
        // Set up a fake grep that sleeps 10s.
        let fakeBin = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("opencode-resolver-fakebin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeGrep = fakeBin.appendingPathComponent("grep")
        try """
        #!/bin/bash
        sleep 10
        """.write(to: fakeGrep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGrep.path)

        OpenCodeWorkspaceResolver.grepPath = fakeGrep.path
        OpenCodeWorkspaceResolver.scanTimeout = 0.1
        try writeLog(name: "opencode-2026-06-18.log", contents: """
        ERROR ... https://opencode.ai/workspace/wrk_TIMEOUTTEST00000000/billing
        """)

        let start = Date()
        XCTAssertNil(OpenCodeWorkspaceResolver.resolveWorkspaceID())
        let elapsed = Date().timeIntervalSince(start)

        // The resolver should return as soon as the timeout fires + the child
        // is reaped (2s cap). Give a generous 5s ceiling for slow CI.
        XCTAssertLessThan(elapsed, 5.0,
                          "resolver should return within 5s of timeout, took \(elapsed)s")
        XCTAssertNil(UserDefaults.standard.string(forKey: "opencode.workspaceID"))

        try? FileManager.default.removeItem(at: fakeBin)
    }

    // MARK: - Helpers

    private func writeLog(name: String, contents: String) throws {
        try writeFile(name: name, contents: contents)
    }

    private func writeFile(name: String, contents: String) throws {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
