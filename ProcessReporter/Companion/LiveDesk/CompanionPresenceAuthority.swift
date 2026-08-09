import Foundation

/// A presence authority must serialize all mutations issued through one
/// instance. `YohakuPresenceClient` supplies that ordered send boundary together
/// with its single durable sequencer.
protocol CompanionPresenceSending: AnyObject, Sendable {
    func replacePresence(
        with snapshot: SanitizedPresenceSnapshot,
        requestedLeaseSeconds: Int
    ) async throws -> CompanionPresenceMutationResponseV2

    func clearPresence(
        reason: CompanionPresenceClearReasonV2,
        observedAt: Date
    ) async throws -> CompanionPresenceMutationResponseV2
}

extension YohakuPresenceClient: CompanionPresenceSending {}

private actor CompanionClearCompletionGate {
    private var isSignaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        waiter?.resume()
        waiter = nil
    }
}

enum CompanionPresenceCleanup {
    static func clearBestEffort(
        using client: any CompanionPresenceSending,
        reason: CompanionPresenceClearReasonV2,
        timeout: Duration
    ) async {
        let completion = CompanionClearCompletionGate()
        let clearTask = Task {
            _ = try? await client.clearPresence(reason: reason, observedAt: .now)
            await completion.signal()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await completion.signal()
        }

        // Return as soon as clear completes, with the timeout serving only as an
        // upper bound. Do not join the network task after the deadline;
        // cancellation is best effort and lease expiry remains authoritative.
        await completion.wait()
        clearTask.cancel()
        timeoutTask.cancel()
    }
}

enum CompanionPresenceMutationFailureAction: Equatable, Sendable {
    case degrade
    case refreshCapabilities
}

enum CompanionPresenceMutationFailurePolicy {
    static func action(for error: any Error) -> CompanionPresenceMutationFailureAction {
        guard let clientError = error as? CompanionHTTPClientError,
              case .server(let statusCode, let response) = clientError
        else {
            return .degrade
        }
        if response?.error.code == "COMPANION_SCHEMA_UNSUPPORTED"
            || response?.error.code == "COMPANION_FEATURE_UNAVAILABLE"
        {
            return .refreshCapabilities
        }
        // A 426 response is itself the protocol-level signal when an older or
        // newer server cannot encode an error envelope this client understands.
        if statusCode == 426, response == nil {
            return .refreshCapabilities
        }
        return .degrade
    }
}

struct CompanionPresenceAuthorityKey: Equatable, Sendable {
    let baseURL: URL
    let deviceID: String
}

/// Retains one ordered writer for the lifetime of a paired device connection.
/// A lifecycle restart may renegotiate capabilities, but it must not create a
/// second sequencer or send slot for the same device while an older clear can
/// still be in flight.
@MainActor
final class CompanionPresenceAuthorityRegistry {
    private var key: CompanionPresenceAuthorityKey?
    private(set) var currentClient: (any CompanionPresenceSending)?

    func resolve(
        for requestedKey: CompanionPresenceAuthorityKey,
        makeClient: () -> any CompanionPresenceSending
    ) -> any CompanionPresenceSending {
        if key == requestedKey, let currentClient {
            return currentClient
        }

        let client = makeClient()
        key = requestedKey
        currentClient = client
        return client
    }

    func discard() {
        key = nil
        currentClient = nil
    }
}
