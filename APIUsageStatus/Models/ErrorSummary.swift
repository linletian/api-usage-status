import Foundation

// MARK: - ErrorType

enum ErrorType: Equatable {
    case networkTimeout
    case networkUnreachable
    case authFailed          // 401/403
    case apiError(code: Int)

    var displayMessage: String {
        switch self {
        case .networkTimeout:
            return "Network timeout"
        case .networkUnreachable:
            return "Network unreachable"
        case .authFailed:
            return "API Key invalid"
        case .apiError(let code):
            return "API error (code: \(code))"
        }
    }
}

// MARK: - RefreshError

enum RefreshError: Error, Equatable {
    case networkTimeout
    case networkUnreachable
    case httpError(statusCode: Int)
    case parsingError(String)
    case maxRetriesExceeded

    var errorType: ErrorType {
        switch self {
        case .networkTimeout:
            return .networkTimeout
        case .networkUnreachable:
            return .networkUnreachable
        case .httpError(let code) where code == 401 || code == 403:
            return .authFailed
        case .httpError(let code):
            return .apiError(code: code)
        case .parsingError:
            return .apiError(code: 0)
        case .maxRetriesExceeded:
            return .apiError(code: 0)
        }
    }
}

// MARK: - ErrorSummary

struct ErrorSummary: Identifiable, Equatable {
    let id: String           // Instance UUID
    let displayName: String
    let errorType: ErrorType

    var errorMessage: String {
        switch errorType {
        case .networkTimeout:
            return "Network timeout, retrying soon"
        case .networkUnreachable:
            return "Network unreachable"
        case .authFailed:
            return "API Key invalid, check settings"
        case .apiError(let code):
            return "API error (code: \(code))"
        }
    }
}