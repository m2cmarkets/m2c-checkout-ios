import Foundation

public enum StatusCoercion {
    public static func coerce(_ raw: String) -> ClientStatus {
        switch raw.lowercased() {
        case "completed", "refunded", "chargedback":
            return .completed
        case "failed":
            return .failed
        case "abandoned", "canceled", "cancelled":
            return .canceled
        default:
            return .processing
        }
    }
}

public protocol CheckoutClock: Sendable {
    func now() -> Date
}

public struct SystemCheckoutClock: CheckoutClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol CheckoutSleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TaskCheckoutSleeper: CheckoutSleeper {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        if seconds <= 0 { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public struct StatusPoller: Sendable {
    public let policy: PollPolicy
    public let clock: any CheckoutClock
    public let sleeper: any CheckoutSleeper
    private let readLimiter: StatusReadLimiter

    public init(
        policy: PollPolicy,
        clock: any CheckoutClock = SystemCheckoutClock(),
        sleeper: any CheckoutSleeper = TaskCheckoutSleeper()
    ) {
        self.policy = policy
        self.clock = clock
        self.sleeper = sleeper
        self.readLimiter = .shared
    }

    init(policy: PollPolicy, readLimiter: StatusReadLimiter) {
        self.policy = policy
        self.clock = SystemCheckoutClock()
        self.sleeper = TaskCheckoutSleeper()
        self.readLimiter = readLimiter
    }

    public func poll(
        read: @escaping @Sendable () async throws -> ClientStatus
    ) async throws -> ClientStatus {
        try policy.validate()
        let window = policy.timeout
        let deadline = clock.now().addingTimeInterval(window)
        var index = 0
        while clock.now() < deadline {
            let delay = index < policy.delays.count ? policy.delays[index] : 8
            index += 1
            if delay > 0 {
                let remaining = deadline.timeIntervalSince(clock.now())
                if remaining <= 0 { break }
                try await sleeper.sleep(seconds: min(delay, remaining))
            }
            let remaining = deadline.timeIntervalSince(clock.now())
            if remaining <= 0 { break }
            do {
                try Task.checkCancellation()
                let status = try await readWithin(seconds: remaining, read: read)
                try Task.checkCancellation()
                if status != .processing { return status }
            } catch let error as M2CCheckoutError
                where error.code == .network
                    || error.code == .rateLimited
                    || error.code == .serviceUnavailable {
                if Task.isCancelled { throw CancellationError() }
                if let retryAfter = error.retryAfter, retryAfter > 0 {
                    let remaining = deadline.timeIntervalSince(clock.now())
                    if remaining > 0 {
                        try await sleeper.sleep(seconds: min(retryAfter, remaining))
                    }
                }
                continue
            }
        }
        do {
            try Task.checkCancellation()
            let finalBudget = min(30, max(0.001, window))
            let status = try await readWithin(seconds: finalBudget, read: read)
            try Task.checkCancellation()
            return status
        } catch let error as M2CCheckoutError
            where error.code == .network
                || error.code == .rateLimited
                || error.code == .serviceUnavailable {
            if Task.isCancelled { throw CancellationError() }
            return .processing
        }
    }

    public func readOnce(
        timeout: TimeInterval,
        read: @escaping @Sendable () async throws -> ClientStatus
    ) async throws -> ClientStatus {
        guard timeout.isFinite, timeout > 0 else {
            throw M2CCheckoutError(.invalidRequest, "status read timeout must be positive")
        }
        return try await readWithin(seconds: timeout, read: read)
    }

    private func readWithin(
        seconds: TimeInterval,
        read: @escaping @Sendable () async throws -> ClientStatus
    ) async throws -> ClientStatus {
        guard readLimiter.acquire() else {
            throw M2CCheckoutError(.network, "status read capacity is exhausted")
        }
        let race = StatusReadRace()
        let limiter = readLimiter
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let readTask = Task {
                    defer { limiter.release() }
                    do {
                        race.resolve(.success(try await read()))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        let bounded = min(
                            seconds,
                            TimeInterval(UInt64.max) / 1_000_000_000
                        )
                        try await Task.sleep(
                            nanoseconds: UInt64(max(0.001, bounded) * 1_000_000_000)
                        )
                        race.resolve(
                            .failure(M2CCheckoutError(.network, "status read timed out"))
                        )
                    } catch {
                        // The winning read or parent cancellation stops the timeout task.
                    }
                }
                race.installTasks(read: readTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }
}

final class StatusReadLimiter: @unchecked Sendable {
    static let shared = StatusReadLimiter(maxConcurrent: 4)

    private let lock = NSLock()
    private let maxConcurrent: Int
    private var active = 0

    init(maxConcurrent: Int) {
        precondition(maxConcurrent > 0)
        self.maxConcurrent = maxConcurrent
    }

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < maxConcurrent else { return false }
        active += 1
        return true
    }

    func release() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class StatusReadRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ClientStatus, Error>?
    private var result: Result<ClientStatus, Error>?
    private var readTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<ClientStatus, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installTasks(read: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        if result == nil {
            readTask = read
            timeoutTask = timeout
            lock.unlock()
        } else {
            lock.unlock()
            read.cancel()
            timeout.cancel()
        }
    }

    func resolve(_ result: Result<ClientStatus, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let readTask = readTask
        self.readTask = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        continuation?.resume(with: result)
        readTask?.cancel()
        timeoutTask?.cancel()
    }
}
