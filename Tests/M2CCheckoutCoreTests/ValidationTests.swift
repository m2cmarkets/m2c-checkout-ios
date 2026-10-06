import Foundation
import XCTest
@testable import M2CCheckoutCore

final class ValidationTests: XCTestCase {
    func testCheckoutURLRules() throws {
        XCTAssertNoThrow(try CheckoutValidation.validateCheckoutURL(URL(string: "https://pay.example/x")!))
        XCTAssertNoThrow(try CheckoutValidation.validateCheckoutURL(URL(string: "http://127.2.3.4/x")!))
        XCTAssertNoThrow(try CheckoutValidation.validateCheckoutURL(URL(string: "http://[::1]/x")!))
        XCTAssertThrowsError(
            try CheckoutValidation.validateCheckoutURL(URL(string: "http://pay.example/x")!)
        )
    }

    // Newer Foundation may percent-encode an extra userinfo @ while parsing, so
    // the encoded form must be rejected like the raw one.
    func testCheckoutURLLoopbackRejectsEncodedUserinfoSeparator() {
        XCTAssertNoThrow(try CheckoutValidation.validateCheckoutURL(URL(string: "http://user@127.0.0.1:8090/x")!))
        if let url = URL(string: "http://user%40evil.example@127.0.0.1/x") {
            XCTAssertThrowsError(try CheckoutValidation.validateCheckoutURL(url))
        }
    }

    func testAuctionReferenceMustBeOpaqueID() {
        for reference in ["order_ABC-1.v2:eu", "  order-1  ", "   "] {
            XCTAssertNoThrow(
                try CheckoutValidation.validateRequest(AuctionRequest(transactionValue: 1, reference: reference))
            )
        }
        for reference in ["jane@example.com", "Jane Doe", "https://shop.example/o/1", "caf\u{e9}", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(
                try CheckoutValidation.validateRequest(AuctionRequest(transactionValue: 1, reference: reference))
            ) { error in
                XCTAssertEqual((error as? M2CCheckoutError)?.code, .invalidRequest)
            }
        }
    }

    func testPublishableKeyRejectsSecrets() {
        XCTAssertNoThrow(try CheckoutValidation.validatePublishableKey("pub_test_example"))
        XCTAssertThrowsError(try CheckoutValidation.validatePublishableKey("sk_secret"))
    }

    func testResumeRecordRejectsUnknownAndOversizedValues() throws {
        let record = ResumeRecord(
            requestID: "req_1",
            integrationMode: .client,
            sourceKind: .url,
            statusURLTemplate: "https://merchant.example/{request_id}",
            successReturnURL: "mygame://checkout/return",
            cancelReturnURL: "mygame://checkout/cancel"
        )
        XCTAssertEqual(ResumeRecord.decode(try record.encode()), record)
        XCTAssertNil(ResumeRecord.decode(Data(repeating: 1, count: 16_385)))
        XCTAssertNil(ResumeRecord.decode(Data(#"{"version":2,"requestID":"req"}"#.utf8)))
    }

    func testPollerBoundsEachStatusRead() async throws {
        let started = Date()
        let status = try await StatusPoller(
            policy: PollPolicy(timeout: 0.02, delays: [0])
        ).poll {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .completed
        }

        XCTAssertEqual(status, .processing)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testPollerHonorsRetryAfterBeforeRetrying() async throws {
        let time = AdvancingTestTime()
        let reads = LockedCounter()
        let status = try await StatusPoller(
            policy: PollPolicy(timeout: 5, delays: [0, 0]),
            clock: time,
            sleeper: time
        ).poll {
            if reads.increment() == 1 {
                throw M2CCheckoutError(.rateLimited, "retry later", retryAfter: 2)
            }
            return .completed
        }

        XCTAssertEqual(status, .completed)
        XCTAssertEqual(time.elapsed, 2)
    }

    func testReadOnceBoundsCancellationInsensitiveRead() async throws {
        let started = Date()
        do {
            _ = try await StatusPoller(policy: .default).readOnce(timeout: 0.02) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        continuation.resume()
                    }
                }
                return .completed
            }
            XCTFail("expected bounded read to time out")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .network)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75)
    }

    func testBudgetedPollPreservesRetryAfterAndFinalRead() async throws {
        let time = AdvancingTestTime()
        let budgets = LockedBudgets()
        let status = try await StatusPoller(
            policy: PollPolicy(timeout: 5, delays: [0, 0, 4]),
            clock: time, sleeper: time
        ).pollWithBudget { budget in
            switch budgets.append(budget) {
            case 1:
                throw M2CCheckoutError(.rateLimited, "retry later", retryAfter: 2)
            case 2:
                return .processing
            default:
                return .completed
            }
        }
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(budgets.values, [5, 3, 5])
        XCTAssertEqual(time.elapsed, 5)
    }

    func testPollerDeadlineDoesNotWaitForCancellationInsensitiveRead() async throws {
        let started = Date()
        let status = try await StatusPoller(
            policy: PollPolicy(timeout: 0.02, delays: [])
        ).poll {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    continuation.resume()
                }
            }
            return .completed
        }

        XCTAssertEqual(status, .processing)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75)
    }

    func testPollerCapsCancellationInsensitiveStatusReads() async throws {
        let limiter = StatusReadLimiter(maxConcurrent: 4)
        let blocker = CancellationInsensitiveReadBlocker()

        for _ in 0..<6 {
            let status = try await StatusPoller(
                policy: PollPolicy(timeout: 0.02, delays: [0]),
                readLimiter: limiter
            ).poll {
                await blocker.wait()
                return .completed
            }
            XCTAssertEqual(status, .processing)
        }

        XCTAssertEqual(blocker.started, 4)
        blocker.release()
    }

    func testPollerRejectsUnsafePolicies() async {
        let policies = [
            PollPolicy(timeout: 0, delays: [0]),
            PollPolicy(timeout: .nan, delays: [0]),
            PollPolicy(timeout: .infinity, delays: [0]),
            PollPolicy(timeout: 2_147_483.648, delays: [0]),
            PollPolicy(timeout: 1, delays: [-1]),
            PollPolicy(timeout: 1, delays: [.nan]),
            PollPolicy(timeout: 1, delays: [2_147_483.648])
        ]

        for policy in policies {
            do {
                _ = try await StatusPoller(policy: policy).poll { .processing }
                XCTFail("expected unsafe poll policy to be rejected")
            } catch {
                XCTAssertEqual((error as? M2CCheckoutError)?.code, .invalidRequest)
            }
        }
    }
}

private final class LockedBudgets: @unchecked Sendable {
    private let lock = NSLock()
    private var budgets: [TimeInterval] = []
    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return budgets
    }
    func append(_ budget: TimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }
        budgets.append(budget)
        return budgets.count
    }
}

private final class AdvancingTestTime: CheckoutClock, CheckoutSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    var elapsed: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func now() -> Date {
        Date(timeIntervalSince1970: elapsed)
    }

    func sleep(seconds: TimeInterval) async throws {
        advance(by: seconds)
    }

    private func advance(by seconds: TimeInterval) {
        lock.lock()
        self.seconds += seconds
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class CancellationInsensitiveReadBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startedCount = 0

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            startedCount += 1
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}
