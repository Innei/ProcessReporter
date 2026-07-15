import Foundation

struct PresenceDiagnosticError: Equatable, Sendable {
    let code: String
    let message: String
    let occurredAt: Date
}

@MainActor
final class PresenceDiagnosticsState {
    static let shared = PresenceDiagnosticsState()

    private(set) var lastError: PresenceDiagnosticError?

    func record(code: String, message: String) {
        lastError = PresenceDiagnosticError(
            code: code,
            message: message,
            occurredAt: .now
        )
    }
}

