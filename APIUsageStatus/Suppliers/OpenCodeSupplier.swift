import Foundation

/// Fetches OpenCode Go usage from a local SQLite DB via the `opencode` CLI.
///
/// OpenCode has no remote HTTP API, so this supplier shells out to
/// `opencode db "..." --format json` to query `~/.local/share/opencode/opencode.db`.
/// The three windows (5h, weekly, monthly) are computed in SQL with `SUM(cost)`
/// over different time ranges; the three reset times come from
/// `OpenCodeResponseParser` (rolling-5h, next-Monday-UTC, anchor-day-of-month).
///
/// The `apiKey` parameter is ignored — OpenCode does not use credentials.
struct OpenCodeSupplier: Supplier {
    let provider: Provider = .opencode

    private let runner: ShellProcessRunner
    private let parser: OpenCodeResponseParser
    private let logger = AppLogger(category: "opencode-supplier")

    init(runner: ShellProcessRunner = .shared, parser: OpenCodeResponseParser = .init()) {
        self.runner = runner
        self.parser = parser
    }

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let opencodePath: String
        do {
            opencodePath = try Self.locateOpencode()
        } catch {
            throw RefreshError.parsingError(error.localizedDescription)
        }

        let now = Date()
        let fiveHourMs = Self.millis(now.addingTimeInterval(-5 * 3600))
        let weekStartMs = Self.millis(OpenCodeResponseParser.nextMondayMidnightUTC(
            from: now.addingTimeInterval(-7 * 86400)
        ))

        let primarySQL = Self.primarySQL
            .replacingOccurrences(of: "{five_hour_ms}", with: String(fiveHourMs))
            .replacingOccurrences(of: "{week_start_ms}", with: String(weekStartMs))

        let primaryData: Data
        do {
            primaryData = try await runner.run(ShellCommand(
                executable: opencodePath,
                arguments: ["db", primarySQL, "--format", "json"],
                timeout: 10
            ))
        } catch {
            throw mapShellError(error)
        }

        let primary: OpenCodeResponseParser.ParsedPrimary
        do {
            primary = try parser.parsePrimary(primaryData)
        } catch {
            throw RefreshError.parsingError("OpenCode primary: \(error.localizedDescription)")
        }

        let monthlyCost: Double
        if let anchorMs = primary.anchorMs {
            let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1000)
            let monthlyEnd = OpenCodeResponseParser.anchoredMonthEnd(now: now, anchor: anchor)
            let monthlyStart = monthlyEnd.addingTimeInterval(-30 * 86400)
            let monthSQL = Self.monthlySQL
                .replacingOccurrences(of: "{month_start_ms}", with: String(Self.millis(monthlyStart)))
                .replacingOccurrences(of: "{month_end_ms}", with: String(Self.millis(monthlyEnd)))
            do {
                let monthlyData = try await runner.run(ShellCommand(
                    executable: opencodePath,
                    arguments: ["db", monthSQL, "--format", "json"],
                    timeout: 10
                ))
                monthlyCost = try parser.parseMonthly(monthlyData)
            } catch {
                throw mapShellError(error)
            }
        } else {
            monthlyCost = 0
        }

        let parsed = parser.buildParsed(primary: primary, monthlyCost: monthlyCost, now: now)
        return Self.makeResponse(from: parsed)
    }

    // MARK: - rawData key design

    /// Three `Instance`s share one `api_key_ref` (the placeholder in
    /// `KeychainService.openCodePlaceholderKey`). `RefreshService` de-dupes
    /// the fetch, so `fetchUsage` is called once and writes all three
    /// dimensions' data into `rawData`. Each `Instance` then picks its own
    /// dimension via `mapInstanceToSlotData`.
    ///
    /// Keys follow the existing `MiniMax` convention: bare key for the
    /// percent, and `<dim>:used`, `<dim>:limit`, `<dim>:end_time` for
    /// values that `RefreshService` already knows how to read.
    static func makeResponse(from parsed: OpenCodeResponseParser.Parsed) -> SupplierResponse {
        var raw: [String: String] = [:]
        for (dim, window) in [
            ("5h", parsed.fiveHour),
            ("weekly", parsed.weekly),
            ("monthly", parsed.monthly)
        ] {
            raw[dim] = String(format: "%.1f", window.percent)
            raw["\(dim):used"] = String(format: "%.2f", window.used)
            raw["\(dim):limit"] = String(format: "%.2f", window.limit)
            if let end = window.endTimeMs {
                raw["\(dim):end_time"] = String(end)
            }
        }
        return SupplierResponse(rawData: raw, currency: "USD", isAvailable: true)
    }

    // MARK: - CLI discovery

    private static let opencodePathCandidates: [String] = [
        "\(NSHomeDirectory())/.opencode/bin/opencode",
        "/usr/local/bin/opencode",
        "/opt/homebrew/bin/opencode"
    ]

    static func locateOpencode() throws -> String {
        for path in opencodePathCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw ShellError.executableNotFound(path: "opencode (checked: \(opencodePathCandidates.joined(separator: ", ")))")
    }

    static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func mapShellError(_ error: Error) -> RefreshError {
        if let shell = error as? ShellError {
            switch shell {
            case .executableNotFound, .launchFailed:
                return RefreshError.parsingError(shell.localizedDescription)
            case .nonZeroExit(_, let stderr):
                return RefreshError.parsingError("opencode db failed: \(stderr)")
            case .timedOut:
                return RefreshError.networkTimeout
            }
        }
        return RefreshError.parsingError(error.localizedDescription)
    }

    // MARK: - SQL templates (kept in sync with docs/provider-interfaces/opencode_go.md)
    //
    // Safety: The {five_hour_ms}, {week_start_ms}, {month_start_ms}, and
    // {month_end_ms} placeholders are replaced with Int64 millisecond values
    // computed from Date — not user input. No SQL injection surface.

    private static let primarySQL = """
    SELECT
      COALESCE(SUM(CASE WHEN t >= {five_hour_ms}  THEN cost ELSE 0 END), 0) AS five_hour_cost,
      COALESCE(SUM(CASE WHEN t >= {week_start_ms} THEN cost ELSE 0 END), 0) AS weekly_cost,
      MIN(CASE WHEN t >= {five_hour_ms} THEN t ELSE NULL END) AS five_hour_oldest_ms,
      MIN(t) AS anchor_ms
    FROM (
      SELECT
        CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS t,
        CAST(json_extract(data, '$.cost') AS REAL) AS cost
      FROM message
      WHERE json_valid(data)
        AND json_extract(data, '$.providerID') = 'opencode-go'
        AND json_extract(data, '$.role') = 'assistant'
        AND json_type(data, '$.cost') IN ('integer', 'real')
    )
    """

    private static let monthlySQL = """
    SELECT COALESCE(SUM(cost), 0) AS monthly_cost
    FROM (
      SELECT
        CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS t,
        CAST(json_extract(data, '$.cost') AS REAL) AS cost
      FROM message
      WHERE json_valid(data)
        AND json_extract(data, '$.providerID') = 'opencode-go'
        AND json_extract(data, '$.role') = 'assistant'
        AND json_type(data, '$.cost') IN ('integer', 'real')
    )
    WHERE t >= {month_start_ms} AND t < {month_end_ms}
    """
}
