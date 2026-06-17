import Foundation

// MARK: - Provider SF Symbols
//
// Maps each Provider to a representative SF Symbol name used by the
// menu bar and settings UI to visually distinguish providers.
// All symbols are guaranteed to be present in macOS 13+.

extension Provider {
    /// SF Symbol name that visually represents this provider.
    ///
    /// - `minimax` → `"cpu"` — local compute, generic AI inference
    /// - `deepseek` → `"dollarsign.circle"` — paid balance tracking
    /// - `githubCopilot` → `"hammer"` — developer tool
    /// - `opencode` → `"terminal"` — local CLI-driven workflow
    var sfSymbolName: String {
        switch self {
        case .minimax: return "cpu"
        case .deepseek: return "dollarsign.circle"
        case .githubCopilot: return "hammer"
        case .opencode: return "terminal"
        }
    }
}
