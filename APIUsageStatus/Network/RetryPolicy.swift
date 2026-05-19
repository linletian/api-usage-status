import Foundation

// MARK: - RetryPolicy

struct RetryPolicy {
    /// Maximum number of retry attempts (including the initial attempt).
    /// With maxAttempts = 3: 1 initial + 2 retries.
    static let maxAttempts = 3

    /// Singleton instance
    static let shared = RetryPolicy()

    /// Executes the given operation with exponential backoff and jitter.
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (default 3)
    ///   - operation: The async operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error if all attempts fail
    func withRetry<T>(
        maxAttempts: Int = Self.maxAttempts,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                if attempt < maxAttempts - 1 {
                    // Retry delays per spec: 100ms, 1s+jitter, 2s+jitter
                    let delay: Double
                    if attempt == 0 {
                        // First retry: 100ms
                        delay = 0.1 + Double.random(in: 0...0.05)
                    } else {
                        // Subsequent retries: exponential backoff
                        delay = pow(2.0, Double(attempt - 1)) + Double.random(in: 0...1)
                    }
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }

        throw lastError ?? RefreshError.maxRetriesExceeded
    }
}