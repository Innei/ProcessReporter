import Foundation

/// Serializes settings transactions that span Keychain work and MainActor relay
/// publication. The Keychain queue alone cannot protect the await boundary where
/// another UI action could otherwise publish a conflicting settings snapshot.
@MainActor
final class SettingsMutationCoordinator {
    static let shared = SettingsMutationCoordinator()

    private var tail: Task<Void, Never>?
    private var isAcceptingOperations = true

    private init() {}

    @discardableResult
    func enqueue(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard isAcceptingOperations else { return nil }

        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        return task
    }

    func drain() async {
        // Closing admission before suspending guarantees that no transaction can
        // replace tail while termination is waiting for the current snapshot.
        isAcceptingOperations = false
        let pending = tail
        await pending?.value
    }
}
