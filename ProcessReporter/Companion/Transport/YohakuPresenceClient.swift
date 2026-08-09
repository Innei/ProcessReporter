import Foundation

enum CompanionSequenceError: Error, Equatable, Sendable {
    case exhausted
    case invalidStoredValue
}

protocol CompanionSequencePersistence: Sendable {
    func loadNextSequence(for deviceID: String) async throws -> Int?
    func storeNextSequence(_ sequence: Int, for deviceID: String) async throws
    func removeSequence(for deviceID: String) async throws
}

actor UserDefaultsCompanionSequencePersistence: CompanionSequencePersistence {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "companion.presence.next-sequence."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func loadNextSequence(for deviceID: String) throws -> Int? {
        let key = storageKey(deviceID)
        guard let value = defaults.object(forKey: key) else { return nil }
        guard
            let number = value as? NSNumber,
            number.int64Value >= 0,
            number.int64Value <= Int64(CompanionProtocolV2.maximumSafeInteger)
        else {
            throw CompanionSequenceError.invalidStoredValue
        }
        return Int(number.int64Value)
    }

    func storeNextSequence(_ sequence: Int, for deviceID: String) throws {
        guard sequence >= 0, sequence <= CompanionProtocolV2.maximumSafeInteger else {
            throw CompanionSequenceError.exhausted
        }
        defaults.set(NSNumber(value: Int64(sequence)), forKey: storageKey(deviceID))
    }

    func removeSequence(for deviceID: String) {
        defaults.removeObject(forKey: storageKey(deviceID))
    }

    func removeAllSequences() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func storageKey(_ deviceID: String) -> String {
        keyPrefix + deviceID
    }
}

actor CompanionPresenceSequencer {
    private let deviceID: String
    private let persistence: any CompanionSequencePersistence
    private let pairingNextSequence: Int
    private var nextSequence: Int?
    private var mutationSlotIsOccupied = false
    private var mutationSlotWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        deviceID: String,
        pairingNextSequence: Int,
        persistence: any CompanionSequencePersistence
    ) {
        self.deviceID = deviceID
        self.pairingNextSequence = pairingNextSequence
        self.persistence = persistence
    }

    func reserve() async throws -> Int {
        await acquireMutationSlot()
        defer { releaseMutationSlot() }

        let current = try await resolvedNextSequence()
        guard current < CompanionProtocolV2.maximumSafeInteger else {
            throw CompanionSequenceError.exhausted
        }

        let following = current + 1
        // Persistence is the linearization point. A crash after this write may
        // create a legal gap, but can never reuse the reserved sequence.
        try await persistence.storeNextSequence(following, for: deviceID)
        nextSequence = following
        return current
    }

    func reconcile(acceptedSequence: Int) async throws {
        await acquireMutationSlot()
        defer { releaseMutationSlot() }

        guard acceptedSequence >= 0,
              acceptedSequence < CompanionProtocolV2.maximumSafeInteger
        else {
            throw CompanionSequenceError.exhausted
        }
        let current = try await resolvedNextSequence()
        let reconciled = max(current, acceptedSequence + 1)
        guard reconciled != current else { return }
        try await persistence.storeNextSequence(reconciled, for: deviceID)
        nextSequence = reconciled
    }

    func removePersistedState() async throws {
        await acquireMutationSlot()
        defer { releaseMutationSlot() }

        try await persistence.removeSequence(for: deviceID)
        nextSequence = nil
    }

    private func resolvedNextSequence() async throws -> Int {
        if let nextSequence { return nextSequence }
        guard pairingNextSequence >= 0,
              pairingNextSequence <= CompanionProtocolV2.maximumSafeInteger
        else {
            throw CompanionSequenceError.invalidStoredValue
        }
        let stored = try await persistence.loadNextSequence(for: deviceID)
        let resolved = max(pairingNextSequence, stored ?? pairingNextSequence)
        nextSequence = resolved
        return resolved
    }

    private func acquireMutationSlot() async {
        if !mutationSlotIsOccupied {
            mutationSlotIsOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationSlotWaiters.append(continuation)
        }
    }

    private func releaseMutationSlot() {
        guard !mutationSlotWaiters.isEmpty else {
            mutationSlotIsOccupied = false
            return
        }
        let next = mutationSlotWaiters.removeFirst()
        next.resume()
    }
}

actor YohakuPresenceClient {
    private let credential: CompanionDeviceCredential
    private let mapper: CompanionPresenceDTOMapper
    private let httpClient: CompanionHTTPClient
    private let sequencer: CompanionPresenceSequencer
    private var sendSlotIsOccupied = false
    private var sendSlotWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        credential: CompanionDeviceCredential,
        mapper: CompanionPresenceDTOMapper,
        httpClient: CompanionHTTPClient,
        sequencer: CompanionPresenceSequencer
    ) {
        self.credential = credential
        self.mapper = mapper
        self.httpClient = httpClient
        self.sequencer = sequencer
    }

    func replacePresence(
        with snapshot: SanitizedPresenceSnapshot,
        requestedLeaseSeconds: Int = 90
    ) async throws -> CompanionPresenceMutationResponseV2 {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        let sequence = try await sequencer.reserve()
        let request = try mapper.makePresenceRequest(
            snapshot: snapshot,
            deviceID: credential.deviceID,
            sequence: sequence,
            requestedLeaseSeconds: requestedLeaseSeconds
        )
        return try await performWithSingleRetry(request) { request in
            try await httpClient.replacePresence(request, credential: credential)
        }
    }

    func clearPresence(
        reason: CompanionPresenceClearReasonV2,
        observedAt: Date = .now
    ) async throws -> CompanionPresenceMutationResponseV2 {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        let sequence = try await sequencer.reserve()
        let request = try mapper.makeClearRequest(
            reason: reason,
            observedAt: observedAt,
            deviceID: credential.deviceID,
            sequence: sequence
        )
        return try await performWithSingleRetry(request) { request in
            try await httpClient.clearPresence(request, credential: credential)
        }
    }

    private func performWithSingleRetry<Request: Sendable>(
        _ request: Request,
        operation: (Request) async throws -> CompanionPresenceMutationResponseV2
    ) async throws -> CompanionPresenceMutationResponseV2 {
        do {
            return try await executeAndReconcile(request, operation: operation)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CompanionHTTPClientError {
            try await reconcileSequenceIfPresent(error)
            guard error.isSafeForImmediateIdempotentRetry else { throw error }
            do {
                return try await executeAndReconcile(request, operation: operation)
            } catch let retryError as CompanionHTTPClientError {
                try await reconcileSequenceIfPresent(retryError)
                throw retryError
            }
        } catch {
            // URLSession transport failures are ambiguous: the server may have
            // committed before the connection failed. Retry the exact request,
            // preserving sequence and request ID.
            try Task.checkCancellation()
            do {
                return try await executeAndReconcile(request, operation: operation)
            } catch let retryError as CompanionHTTPClientError {
                try await reconcileSequenceIfPresent(retryError)
                throw retryError
            }
        }
    }

    private func executeAndReconcile<Request: Sendable>(
        _ request: Request,
        operation: (Request) async throws -> CompanionPresenceMutationResponseV2
    ) async throws -> CompanionPresenceMutationResponseV2 {
        let response = try await operation(request)
        try await sequencer.reconcile(acceptedSequence: response.data.acceptedSequence)
        return response
    }

    private func reconcileSequenceIfPresent(_ error: CompanionHTTPClientError) async throws {
        guard case .server(_, let response) = error,
              let acceptedSequence = response?.error.acceptedSequence
        else { return }
        try await sequencer.reconcile(acceptedSequence: acceptedSequence)
    }

    private func acquireSendSlot() async {
        if !sendSlotIsOccupied {
            sendSlotIsOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            sendSlotWaiters.append(continuation)
        }
    }

    private func releaseSendSlot() {
        guard !sendSlotWaiters.isEmpty else {
            sendSlotIsOccupied = false
            return
        }
        let next = sendSlotWaiters.removeFirst()
        next.resume()
    }
}

private extension CompanionHTTPClientError {
    var isSafeForImmediateIdempotentRetry: Bool {
        switch self {
        case .server(let statusCode, let response):
            return (500...599).contains(statusCode) && (response?.error.retryable ?? true)
        case .invalidResponse,
             .responseRequestIDMismatch,
             .unexpectedEmptyResponse,
             .responseDecodingFailed:
            return true
        case .payloadTooLarge, .credentialDeviceMismatch:
            return false
        }
    }
}
