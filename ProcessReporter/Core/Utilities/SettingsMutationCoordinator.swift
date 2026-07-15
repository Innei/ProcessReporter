import Foundation

enum SettingsMutationCoordinatorError: Error {
    case notAcceptingOperations
}

/// Serializes settings transactions that span Keychain work and MainActor relay
/// publication. The Keychain queue alone cannot protect the await boundary where
/// another UI action could otherwise publish a conflicting settings snapshot.
@MainActor
final class SettingsMutationCoordinator {
    static let shared = SettingsMutationCoordinator()

    private var tail: Task<Void, Never>?
    private var isAcceptingOperations = true
	private var isPermanentlyClosed = false

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

    func perform<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        guard isAcceptingOperations else {
            throw SettingsMutationCoordinatorError.notAcceptingOperations
        }

        let previous = tail
        let resultTask = Task<T, Error> { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { @MainActor in
            _ = try? await resultTask.value
        }
        return try await resultTask.value
    }

	/// Runs a destructive maintenance transaction after every operation already
	/// admitted, while rejecting new form saves for the entire suspension window.
	/// Without closing admission synchronously, a credential save initiated while
	/// erase is awaiting Keychain or database I/O can be queued behind the erase
	/// and restore the stale credential snapshot immediately afterward.
	func performExclusive<T: Sendable>(
		_ operation: @escaping @MainActor () async throws -> T
	) async throws -> T {
		guard isAcceptingOperations, !isPermanentlyClosed else {
			throw SettingsMutationCoordinatorError.notAcceptingOperations
		}

		isAcceptingOperations = false
		let previous = tail
		let resultTask = Task<T, Error> { @MainActor in
			await previous?.value
			do {
				let result = try await operation()
				self.finishExclusiveOperation()
				return result
			} catch {
				self.finishExclusiveOperation()
				throw error
			}
		}
		tail = Task { @MainActor in
			_ = try? await resultTask.value
		}
		return try await resultTask.value
	}

	private func finishExclusiveOperation() {
		guard !isPermanentlyClosed else { return }
		isAcceptingOperations = true
	}

    func drain() async {
        // Closing admission before suspending guarantees that no transaction can
        // replace tail while termination is waiting for the current snapshot.
		isPermanentlyClosed = true
        isAcceptingOperations = false
        let pending = tail
        await pending?.value
    }
}
