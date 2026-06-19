import Foundation

/// Resolves the OpenCode Go workspace ID so the popup "See details" link can
/// deep-link straight into the per-workspace usage dashboard
/// (`https://opencode.ai/workspace/<id>/go`).
///
/// OpenCode's backend assigns each account a workspace ID (`wrk_...`) at sign-up,
/// but the value lives server-side only — the CLI does not store it locally,
/// and the Zen HTTP API exposes no `/v1/me` or `/v1/workspace` endpoint that
/// would return it given an API key.
///
/// The one place the ID leaks through is the error body returned when a request
/// hits `https://opencode.ai/zen/go/v1/chat/completions` with an empty balance:
///
///     Insufficient balance. Manage your billing here:
///     https://opencode.ai/workspace/<wrk_id>/billing
///
/// The OpenCode process logs that string to `~/.local/share/opencode/log/*.log`,
/// so we recover the ID by grepping the log directory. Result is cached in
/// `UserDefaults` so we only pay the I/O cost once per user.
///
/// Two read paths:
/// - `cachedWorkspaceID()` — synchronous, cache-only. Safe to call from the
///   SwiftUI view layer; never blocks on I/O.
/// - `resolveWorkspaceID()` — full lookup, scans logs on cache miss. Used by
///   `prewarm()` at app launch and by tests. The view layer should NOT call
///   this; the scan can take up to 5s on first run.
///
/// When no ID can be recovered, callers should fall back to a generic landing
/// page (e.g. `https://opencode.ai/zh/go`) that exposes the sign-in flow.
enum OpenCodeWorkspaceResolver {
    private static let cacheKey = "opencode.workspaceID"
    // Grep pattern: find the workspace URL and include the trailing `/` that
    // always follows the ID in the dashboard URL. Including the slash is what
    // lets the inner Swift regex reject lowercase/mixed-case IDs — without it,
    // `wrk_01kh8.../billing` would be matched as just `wrk_01` (the `[A-Z0-9]`
    // class stops at the first lowercase char), and the Swift side would then
    // happily return that 4-char prefix as a "valid" ID.
    private static let urlRegex = #"https://opencode\.ai/workspace/wrk_[A-Z0-9]+/"#
    // Swift pattern: matches `wrk_<id>` only when followed by `/`. Combined
    // with the grep pattern above, a lowercase ID like `wrk_01kh8...` will
    // never produce a grep hit in the first place, so this is a defense in
    // depth check (and what runs when the line is fed by hand in tests).
    private static let idRegex  = #"wrk_[A-Z0-9]+(?=/)"#
    /// Maximum wall-clock time the grep child is allowed before being killed.
    /// `var` so tests can tighten it.
    static var scanTimeout: TimeInterval = 5
    /// Path to the grep binary. `var` so tests can substitute a fake/stub
    /// binary or point at a nonexistent path to exercise error branches.
    static var grepPath: String = "/usr/bin/grep"
    private static let logger = AppLogger.opencode
    /// Serial queue for cache refresh operations. Prevents `prewarm()` and
    /// `refreshCache()` from racing on `clearCache()` + `resolveWorkspaceID()`.
    private static let scanQueue = DispatchQueue(label: "opencode.workspace-resolver", qos: .utility)

    // Hoisted out of scanLogs to avoid re-compiling per line.
    private static let idMatcher: Regex<AnyRegexOutput> = {
        guard let matcher = try? Regex(idRegex) else {
            fatalError("OpenCodeWorkspaceResolver: invalid idRegex pattern '\(idRegex)'")
        }
        return matcher
    }()

    // Reference sample of the canonical wrk_ ID format. Used by the
    // debug-only `validateFormatContract` check below to flag any future
    // drift in the wrk_ ID character set (e.g. if OpenCode mixes in lowercase).
    // Update this constant if a new format is verified — the assert will then
    // catch the next regression on dev/test runs.
    private static let knownGoodSample = "wrk_01ABCDEFGHIJKLMNOPQRSTUVWX"

    /// Confirms the regex still matches the canonical wrk_ format. Runs only
    /// in debug builds (`assert` is a no-op in `-O` release builds), so this
    /// is free in production but catches character-set drift during dev.
    private static func validateFormatContract() {
        assert(
            knownGoodSample.firstMatch(of: idMatcher) != nil,
            "OpenCodeWorkspaceResolver regex \(idRegex) no longer matches the canonical wrk_ format (sample: \(knownGoodSample)). The character set may have changed — update the regex and knownGoodSample."
        )
    }

    /// Test-only override. When non-nil, log scanning is restricted to this
    /// single directory. Production callers leave it nil.
    ///
    /// Caveat: this is a global mutable on a `static`-only enum. XCTest runs
    /// cases serially by default so the test file is safe today, but if a
    /// future test framework parallelises them, two cases could race on this
    /// (and on `grepPath` / `scanTimeout`). If that becomes a concern, switch
    /// the resolver to instance-based and instantiate one per test.
    static var testDirectoryOverride: String?

    /// Directories to scan, in priority order. The default matches
    /// `opencode debug paths` output on macOS.
    static var logDirectoryCandidates: [String] {
        if let override = testDirectoryOverride {
            return [override]
        }
        var paths = ["\(NSHomeDirectory())/.local/share/opencode/log"]
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !xdg.isEmpty {
            paths.append("\(xdg)/opencode/log")
        }
        return paths
    }

    /// Cache-only lookup. Safe to call from view bodies — never triggers the
    /// log scan, so it cannot block the main thread. Returns nil if the cache
    /// is empty (in which case the caller should use the fallback URL).
    static func cachedWorkspaceID() -> String? {
        guard let cached = UserDefaults.standard.string(forKey: cacheKey),
              !cached.isEmpty
        else { return nil }
        return cached
    }

    /// Full lookup: returns the cached ID immediately if present, otherwise
    /// scans the log directory. Synchronous and may take up to `scanTimeout`
    /// seconds on cache miss — call from a background context only.
    static func resolveWorkspaceID() -> String? {
        validateFormatContract()
        if let cached = cachedWorkspaceID() {
            return cached
        }
        guard let id = scanLogs() else { return nil }
        UserDefaults.standard.set(id, forKey: cacheKey)
        return id
    }

    /// Shared implementation for `prewarm()` and `refreshCache()`. Serialized
    /// via `scanQueue` so the two call sites cannot race on cache clearing.
    private static func performCacheRefresh() {
        clearCache()
        _ = resolveWorkspaceID()
    }

    /// Kicks off a background log scan to populate the cache. Safe to call
    /// from `applicationDidFinishLaunching`. The view layer reads via
    /// `cachedWorkspaceID()` and will start returning the workspace URL
    /// on the next render after the scan completes.
    ///
    /// Always clears the existing cache before scanning so a workspace-ID
    /// change (e.g. user switched OpenCode accounts) is picked up
    /// automatically on the next launch.
    static func prewarm() {
        scanQueue.async(execute: performCacheRefresh)
    }

    /// Clears the cache and kicks off a background rescan. Designed for
    /// periodic calls (e.g. after every OpenCode refresh) so a workspace-ID
    /// change is detected without restarting the app. The view layer reads
    /// via `cachedWorkspaceID()` and will pick up the new ID on the next
    /// render after the scan completes.
    static func refreshCache() {
        scanQueue.async(execute: performCacheRefresh)
    }

    /// Drops the cached ID. Used by tests and for manual reset.
    static func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    // MARK: - Log scanning

    private static func scanLogs() -> String? {
        let fm = FileManager.default
        var triedAnyDirectory = false
        for dir in logDirectoryCandidates {
            guard fm.fileExists(atPath: dir) else { continue }
            triedAnyDirectory = true

            let entries: [String]
            do {
                entries = try fm.contentsOfDirectory(atPath: dir)
            } catch {
                logger.warning("contentsOfDirectory failed for \(dir): \(error.localizedDescription)")
                continue
            }

            let logFiles = entries
                .filter { $0.hasSuffix(".log") }
                .sorted()
                .map { "\(dir)/\($0)" }
            guard !logFiles.isEmpty else {
                logger.info("no .log files under \(dir); skipping")
                continue
            }

            // grep -hoE prints only matching portions, one per line, no file
            // names. We pipe the pattern as the first argument and the list of
            // files afterwards — keeps memory bounded regardless of log size.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: grepPath)
            process.arguments = ["-hoE", urlRegex] + logFiles

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                logger.warning("failed to launch \(grepPath): \(error.localizedDescription)")
                continue
            }

            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }
            if semaphore.wait(timeout: .now() + scanTimeout) == .timedOut {
                process.terminate()
                // Reap the SIGTERM'd child. Without this, the child becomes a
                // zombie until our process exits, leaking the file descriptor
                // and (briefly) the process table entry. `process.isRunning`
                // flips to false once waitpid completes; bound the wait so a
                // child stuck in uninterruptible I/O can't hang us.
                let reapStart = Date()
                while process.isRunning,
                      Date().timeIntervalSince(reapStart) < 2 {
                    // Blocking sleep is appropriate here — this runs on a
                    // background queue while waiting for the child to exit.
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    logger.fault("grep did not exit within 2s of SIGTERM; abandoning wait")
                }
                logger.warning("grep timed out after \(Int(scanTimeout))s scanning \(logFiles.count) log file(s) under \(dir)")
                continue
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let exitCode = process.terminationStatus

            if exitCode == 1 {
                // grep returns 1 when no lines match — expected for users
                // who have never triggered an insufficient-balance error.
                logger.info("no wrk_ URL found in \(logFiles.count) log file(s) under \(dir)")
                continue
            }
            guard exitCode == 0 else {
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                logger.warning("grep exited with code \(exitCode) for \(dir): \(stderrStr)")
                continue
            }

            guard let output = String(data: data, encoding: .utf8) else { continue }
            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let match = trimmed.firstMatch(of: idMatcher)
                else { continue }
                let id = String(trimmed[match.range])
                logger.info("recovered workspace id \(id) from \(dir)")
                return id
            }
        }
        if !triedAnyDirectory {
            logger.info("no opencode log directory found at any candidate path")
        }
        return nil
    }
}
