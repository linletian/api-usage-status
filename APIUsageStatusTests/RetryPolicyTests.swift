import XCTest
@testable import APIUsageStatus

final class RetryPolicyTests: XCTestCase {

    func testFirstAttemptSucceeds() async throws {
        var attemptCount = 0
        let policy = RetryPolicy.shared

        let result: String = try await policy.withRetry(maxAttempts: 3) {
            attemptCount += 1
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 1)
    }

    func testSecondAttemptSucceeds() async throws {
        var attemptCount = 0
        let policy = RetryPolicy.shared

        let start = Date()
        let result: String = try await policy.withRetry(maxAttempts: 3) {
            attemptCount += 1
            if attemptCount < 2 {
                throw RefreshError.networkTimeout
            }
            return "success"
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 2)
        XCTAssertGreaterThan(elapsed, 0.05)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testThirdAttemptSucceeds() async throws {
        var attemptCount = 0
        let policy = RetryPolicy.shared

        let result: String = try await policy.withRetry(maxAttempts: 3) {
            attemptCount += 1
            if attemptCount < 3 {
                throw RefreshError.networkTimeout
            }
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 3)
    }

    func testAllAttemptsFail() async {
        var attemptCount = 0
        let policy = RetryPolicy.shared

        do {
            let _: String = try await policy.withRetry(maxAttempts: 3) {
                attemptCount += 1
                throw RefreshError.networkTimeout
            }
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(attemptCount, 3)
        }
    }

    func testRetryDelayApproximatelyCorrect() async throws {
        var attemptCount = 0
        let policy = RetryPolicy.shared

        let start = Date()
        let _: String = try await policy.withRetry(maxAttempts: 3) {
            attemptCount += 1
            if attemptCount < 3 {
                throw RefreshError.networkTimeout
            }
            return "success"
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(attemptCount, 3)
        XCTAssertGreaterThan(elapsed, 1.0)
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testCustomMaxAttempts() async {
        var attemptCount = 0
        let policy = RetryPolicy.shared

        do {
            let _: String = try await policy.withRetry(maxAttempts: 2) {
                attemptCount += 1
                throw RefreshError.networkTimeout
            }
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(attemptCount, 2)
        }
    }
}
