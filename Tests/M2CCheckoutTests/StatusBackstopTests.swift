import AuthenticationServices
import Foundation
import UIKit
import XCTest
@testable import M2CCheckout
@testable import M2CCheckoutCore

@MainActor
final class StatusBackstopTests: XCTestCase {
    func testURLAndCallbackProcessingAndRetryableErrorsReachBackstop() async throws {
        for url in [false, true] {
            let codes: [M2CCheckoutErrorCode?] = [nil, .network, .rateLimited, .serviceUnavailable]
            for code in codes {
                let time = BackstopTime()
                let transport = BackstopTransport(primary: {
                    time.advance(10)
                    if let code { throw M2CCheckoutError(code, "primary unavailable") }
                    return .processing
                })
                let client = try client(source: source(url, transport), transport: transport, time: time)
                let status = try await client.checkStatus(requestID: "req_original")
                XCTAssertEqual(status, .completed)
                XCTAssertEqual(transport.primaryCalls, 1)
                XCTAssertEqual(transport.backstopCalls, 1)
                XCTAssertEqual(transport.auctionCalls, 0)
            }
        }
    }

    func testResolvedPrimaryWinsAndDisabledOrIneligibleBackstopIsNotRead() async throws {
        for status in [ClientStatus.completed, .failed, .canceled, .processing] {
            for enabled in [false, true] {
                let time = BackstopTime()
                let transport = BackstopTransport(primary: {
                    time.advance(status == .processing ? 1 : 10)
                    return status
                })
                let client = try client(source: source(false, transport), transport: transport, time: time, enabled: enabled)
                let result = try await client.checkStatus(requestID: "req_original")
                XCTAssertEqual(result, status)
                XCTAssertEqual(transport.backstopCalls, 0)
            }
        }
    }

    func testActionableErrorAndCancellationNeverReadBackstop() async throws {
        for cancellation in [false, true] {
            let time = BackstopTime()
            let transport = BackstopTransport(primary: {
                time.advance(10)
                if cancellation { throw CancellationError() }
                throw M2CCheckoutError(.authenticationFailed, "primary rejected")
            })
            let client = try client(source: source(false, transport), transport: transport, time: time)
            do {
                _ = try await client.checkStatus(requestID: "req_original")
                XCTFail("expected primary error")
            } catch is CancellationError {
                XCTAssertTrue(cancellation)
            } catch let error as M2CCheckoutError {
                XCTAssertFalse(cancellation)
                XCTAssertEqual(error.code, .authenticationFailed)
            }
            XCTAssertEqual(transport.backstopCalls, 0)
        }
    }

    func testRetryableErrorBeforeEligibilityAndProcessingWithUnavailableBackstop() async throws {
        for enabled in [false, true] {
            let time = BackstopTime()
            let transport = BackstopTransport(primary: {
                time.advance(1)
                throw M2CCheckoutError(.network, "original error")
            })
            let client = try client(source: source(false, transport), transport: transport, time: time, enabled: enabled)
            do {
                _ = try await client.checkStatus(requestID: "req_original")
                XCTFail("expected original error")
            } catch let error as M2CCheckoutError { XCTAssertEqual(error.code, .network) }
            XCTAssertEqual(transport.backstopCalls, 0)
        }
        let time = BackstopTime()
        let transport = BackstopTransport(primary: { time.advance(10); return .processing }, backstop: {
            throw M2CCheckoutError(.authenticationFailed, "secondary rejected")
        })
        let client = try client(source: source(false, transport), transport: transport, time: time)
        let status = try await client.checkStatus(requestID: "req_original")
        XCTAssertEqual(status, .processing)
        XCTAssertEqual(transport.backstopCalls, 1)
    }

    func testUnresolvedOrUnavailableBackstopPreservesPrimaryError() async throws {
        for backstopError in [false, true] {
            let time = BackstopTime()
            let transport = BackstopTransport(primary: {
                time.advance(10)
                throw M2CCheckoutError(.rateLimited, "original primary error", retryAfter: 2)
            }, backstop: {
                if backstopError { throw M2CCheckoutError(.authenticationFailed, "secondary rejected") }
                return .processing
            })
            let client = try client(source: source(true, transport), transport: transport, time: time)
            do {
                _ = try await client.checkStatus(requestID: "req_original")
                XCTFail("expected original primary error")
            } catch let error as M2CCheckoutError {
                XCTAssertEqual(error.code, .rateLimited)
                XCTAssertEqual(error.message, "original primary error")
            }
            XCTAssertEqual(transport.backstopCalls, 1)
        }
    }

    func testM2CPrimaryReadsOnceAndMissingBackstopKeyIsRejected() async throws {
        let transport = BackstopTransport(primary: { .processing })
        let client = try client(source: .m2c, transport: transport, time: BackstopTime(), enabled: false)
        let status = try await client.checkStatus(requestID: "req_original")
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(transport.backstopCalls, 1)
        XCTAssertThrowsError(try M2CCheckoutClient(config: M2CCheckoutConfig(
            returnURLs: returnURLs,
            statusSource: .callback { _ in .processing },
            statusBackstop: .init(enabled: true)
        )))
    }

    func testShortPollReservesOneBackstopBeforeThresholdWithoutAnotherCheckout() async throws {
        let time = BackstopTime()
        let store = BackstopStore()
        let transport = BackstopTransport(primary: { .processing })
        let client = try client(source: source(false, transport), transport: transport, time: time, store: store, timeout: 1)
        let result = try await client.start(session: session, presentationContext: BackstopPresentation())
        XCTAssertEqual(result, .completed(requestID: "req_original"))
        XCTAssertEqual(transport.backstopCalls, 1)
        XCTAssertEqual(transport.auctionCalls, 0)
        XCTAssertGreaterThanOrEqual(time.now().timeIntervalSince1970, 0.5)
        XCTAssertLessThanOrEqual(time.now().timeIntervalSince1970, 1)
        XCTAssertNil(store.record)
    }

    func testSavedURLRemainsPrimaryDuringRecoveryAndUsesBackstop() async throws {
        let time = BackstopTime()
        let store = BackstopStore()
        store.record = ResumeRecord(
            requestID: "req_original", integrationMode: .backend, sourceKind: .url,
            statusURLTemplate: "https://original.example/status/{request_id}",
            successReturnURL: returnURLs.success.absoluteString,
            cancelReturnURL: returnURLs.cancel.absoluteString
        )
        let transport = BackstopTransport(primary: {
            time.advance(10)
            throw M2CCheckoutError(.network, "original unavailable")
        })
        let client = try client(
            source: .url(template: "https://current.example/status/{request_id}"),
            transport: transport, time: time, store: store
        )
        let result = try await client.tryResume()
        XCTAssertEqual(result, .completed(requestID: "req_original"))
        XCTAssertEqual(transport.templates, ["https://original.example/status/{request_id}"])
        XCTAssertEqual(transport.backstopCalls, 1)
        XCTAssertNil(store.record)
    }

    func testSavedM2CPrimaryIsNotBackedUpWithAnotherM2CRead() async throws {
        let time = BackstopTime()
        let store = BackstopStore()
        store.record = ResumeRecord(
            requestID: "req_original", integrationMode: .client, sourceKind: .m2c,
            successReturnURL: returnURLs.success.absoluteString,
            cancelReturnURL: returnURLs.cancel.absoluteString
        )
        let transport = BackstopTransport(primary: { XCTFail("unexpected merchant read"); return .processing })
        let client = try client(source: source(true, transport), transport: transport, time: time, store: store)
        let result = try await client.tryResume()
        XCTAssertEqual(result, .completed(requestID: "req_original"))
        XCTAssertEqual(transport.backstopCalls, 1)
        XCTAssertEqual(transport.primaryCalls, 0)
        XCTAssertNil(store.record)
    }

    func testStalledShortPrimaryStillLeavesBoundedBackstopOpportunity() async throws {
        let transport = BackstopTransport(primary: {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .processing
        })
        let client = try M2CCheckoutClient(
            config: configuration(source: source(false, transport), timeout: 0.2),
            transport: transport, browser: BackstopBrowser(), resumeStore: BackstopStore(),
            clock: SystemCheckoutClock(), sleeper: TaskCheckoutSleeper()
        )
        let started = Date()
        let result = try await client.start(session: session, presentationContext: BackstopPresentation())
        XCTAssertEqual(result, .completed(requestID: "req_original"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6)
        XCTAssertEqual(transport.backstopCalls, 1)
    }

    func testLateSuccessAfterUIOutcomesAndDistinctExplicitPurchase() async throws {
        for outcome in [BrowserOutcome.dismissed,
                        .returned(URL(string: "mygame://checkout/cancel")!),
                        .returned(URL(string: "mygame://checkout/return")!)] {
            let time = BackstopTime()
            let store = BackstopStore()
            let payment = BackstopPayment()
            let transport = BackstopTransport(primary: { payment.status() })
            let browser = BackstopBrowser(outcome: outcome)
            let client = try M2CCheckoutClient(
                config: configuration(source: source(false, transport), enabled: false, timeout: 1),
                transport: transport, browser: browser, resumeStore: store, clock: time, sleeper: time
            )
            let original = try await client.start(session: session, presentationContext: BackstopPresentation())
            if case .returned(let url) = outcome, url.host == "checkout", url.path == "/return" {
                XCTAssertEqual(original, .pendingTimeout(requestID: "req_original"))
            } else {
                XCTAssertEqual(original, .canceled(requestID: "req_original"))
            }
            XCTAssertNil(store.record)
            XCTAssertEqual(browser.calls, 1)
            payment.complete()
            let lateStatus = try await client.checkStatus(requestID: "req_original")
            XCTAssertEqual(lateStatus, .completed)
            browser.outcome = .ambiguous
            let distinct = try await client.start(
                session: CheckoutSession(checkoutURL: session.checkoutURL, requestID: "req_distinct"),
                presentationContext: BackstopPresentation()
            )
            XCTAssertEqual(distinct, .completed(requestID: "req_distinct"))
            XCTAssertEqual(browser.calls, 2)
            XCTAssertEqual(transport.auctionCalls, 0)
        }
    }

    func testPollingAndRecoveryUseLastReadSlotWhileCancelledReadsRemainActive() async throws {
        let entered = expectation(description: "three status reads started")
        entered.expectedFulfillmentCount = 3
        let blocker = BackstopReadBlocker()
        let blockedTransport = BackstopTransport(primary: {
            await blocker.wait(entered: entered)
            return .processing
        })
        let blockedClient = try M2CCheckoutClient(
            config: configuration(source: source(false, blockedTransport), enabled: false),
            transport: blockedTransport, browser: BackstopBrowser(), resumeStore: BackstopStore(),
            clock: SystemCheckoutClock(), sleeper: TaskCheckoutSleeper()
        )
        let tasks = (0..<3).map { index in
            Task { try await blockedClient.checkStatus(requestID: "req_blocked_\(index)") }
        }
        defer {
            tasks.forEach { $0.cancel() }
            blocker.release()
        }
        await fulfillment(of: [entered], timeout: 2)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            do { _ = try await task.value; XCTFail("expected cancellation") }
            catch is CancellationError { }
        }
        for short in [false, true] {
            for backstop in [false, true] {
                let time = BackstopTime()
                let store = BackstopStore()
                let transport = BackstopTransport(primary: {
                    if backstop {
                        if !short { time.advance(10) }
                        return .processing
                    }
                    return .completed
                })
                let client = try client(source: source(true, transport), transport: transport, time: time, store: store)
                let result: CheckoutResult?
                if short {
                    result = try await client.start(session: session, presentationContext: BackstopPresentation())
                } else {
                    store.record = ResumeRecord(
                        requestID: "req_original", integrationMode: .backend, sourceKind: .url,
                        statusURLTemplate: "https://original.example/status/{request_id}",
                        successReturnURL: returnURLs.success.absoluteString,
                        cancelReturnURL: returnURLs.cancel.absoluteString
                    )
                    result = try await client.tryResume()
                }
                XCTAssertEqual(result, .completed(requestID: "req_original"))
                XCTAssertGreaterThan(transport.primaryCalls, 0)
                XCTAssertEqual(transport.backstopCalls, backstop ? 1 : 0)
                XCTAssertEqual(transport.auctionCalls, 0)
                XCTAssertNil(store.record)
            }
        }
    }

    func testCallerCancellationRetainsRecoveryUntilLateSuccessWithoutAnotherPayment() async throws {
        let entered = expectation(description: "primary status started")
        let store = BackstopStore()
        let payment = BackstopPayment()
        let transport = BackstopTransport(primary: {
            if payment.status() == .completed { return .completed }
            entered.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .processing
        })
        let browser = BackstopBrowser()
        let client = try M2CCheckoutClient(
            config: configuration(source: source(false, transport)),
            transport: transport, browser: browser, resumeStore: store,
            clock: SystemCheckoutClock(), sleeper: TaskCheckoutSleeper()
        )
        let task = Task { try await client.start(session: session, presentationContext: BackstopPresentation()) }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(store.record?.requestID, "req_original")
        do {
            _ = try await client.start(session: session, presentationContext: BackstopPresentation())
            XCTFail("expected pending recovery to block checkout")
        } catch let error as M2CCheckoutError { XCTAssertEqual(error.code, .invalidRequest) }
        XCTAssertEqual(browser.calls, 1)
        payment.complete()
        let resumed = try await client.tryResume()
        XCTAssertEqual(resumed, .completed(requestID: "req_original"))
        XCTAssertNil(store.record)
        let distinct = try await client.start(
            session: CheckoutSession(checkoutURL: session.checkoutURL, requestID: "req_distinct"),
            presentationContext: BackstopPresentation()
        )
        XCTAssertEqual(distinct, .completed(requestID: "req_distinct"))
        XCTAssertEqual(browser.calls, 2)
        XCTAssertEqual(transport.backstopCalls, 0)
        XCTAssertEqual(transport.auctionCalls, 0)
    }

    private var returnURLs: ReturnURLs {
        ReturnURLs(success: URL(string: "mygame://checkout/return")!, cancel: URL(string: "mygame://checkout/cancel")!)
    }

    private var session: CheckoutSession {
        CheckoutSession(checkoutURL: URL(string: "https://vendor.example/pay")!, requestID: "req_original")
    }

    private func source(_ url: Bool, _ transport: BackstopTransport) -> StatusSource {
        url ? .url(template: "https://merchant.example/status/{request_id}")
            : .callback { _ in try await transport.readPrimary() }
    }

    private func configuration(source: StatusSource, enabled: Bool = true, timeout: TimeInterval = 20) -> M2CCheckoutConfig {
        M2CCheckoutConfig(publishableKey: "pub_test_example", returnURLs: returnURLs,
                          statusSource: source, poll: PollPolicy(timeout: timeout, delays: [0, 0.25, 0.5]),
                          statusBackstop: .init(enabled: enabled, threshold: 5))
    }

    private func client(source: StatusSource, transport: BackstopTransport, time: BackstopTime,
                        store: BackstopStore? = nil, enabled: Bool = true, timeout: TimeInterval = 20) throws -> M2CCheckoutClient {
        try M2CCheckoutClient(config: configuration(source: source, enabled: enabled, timeout: timeout),
                              transport: transport, browser: BackstopBrowser(), resumeStore: store ?? BackstopStore(), clock: time, sleeper: time)
    }
}

private final class BackstopReadBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait(entered: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
            entered.fulfill()
        }
    }
    func release() {
        lock.lock()
        released = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

private final class BackstopTime: CheckoutClock, CheckoutSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: seconds)
    }
    func advance(_ amount: TimeInterval) {
        lock.lock()
        seconds += amount
        lock.unlock()
    }
    func sleep(seconds: TimeInterval) async throws { advance(seconds) }
}

private final class BackstopPayment: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func complete() { lock.lock(); completed = true; lock.unlock() }
    func status() -> ClientStatus {
        lock.lock()
        defer { lock.unlock() }
        return completed ? .completed : .processing
    }
}

private final class BackstopTransport: CheckoutTransporting, @unchecked Sendable {
    private let primary: @Sendable () async throws -> ClientStatus
    private let backstop: @Sendable () async throws -> ClientStatus
    private let lock = NSLock()
    private(set) var primaryCalls = 0
    private(set) var backstopCalls = 0
    private(set) var auctionCalls = 0
    private(set) var templates: [String] = []
    init(primary: @escaping @Sendable () async throws -> ClientStatus,
         backstop: @escaping @Sendable () async throws -> ClientStatus = { .completed }) {
        self.primary = primary
        self.backstop = backstop
    }
    private func record(_ kind: Int, template: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if kind == 0 { primaryCalls += 1 }
        if kind == 1 { backstopCalls += 1 }
        if kind == 2 { auctionCalls += 1 }
        if let template { templates.append(template) }
    }
    func readPrimary() async throws -> ClientStatus { record(0); return try await primary() }
    func readURLStatus(template: String, requestID: String) async throws -> ClientStatus {
        record(0, template: template)
        return try await primary()
    }
    func readM2CStatus(requestID: String, publishableKey: String) async throws -> ClientStatus {
        record(1)
        return try await backstop()
    }
    func createAuction(request: AuctionRequest, returnURLs: ReturnURLs, publishableKey: String, timeout: TimeInterval) async throws -> CheckoutSession {
        record(2)
        throw M2CCheckoutError(.invalidRequest, "unexpected checkout initiation")
    }
}

@MainActor
private final class BackstopStore: ResumeStoring {
    var record: ResumeRecord?
    func load() -> ResumeRecord? { record }
    func save(_ record: ResumeRecord) throws { self.record = record }
    func clear() { record = nil }
}

@MainActor
private final class BackstopBrowser: BrowserPresenting {
    var outcome: BrowserOutcome
    var calls = 0
    init(outcome: BrowserOutcome = .ambiguous) { self.outcome = outcome }
    func open(checkoutURL: URL, callbackURL: URL, mode: BrowserMode,
                 presentationContext: M2CCheckoutPresentationContextProviding,
                 onExposed: @MainActor @escaping () -> Void) async throws -> BrowserOutcome {
        onExposed()
        calls += 1
        return outcome
    }
}

@MainActor
private final class BackstopPresentation: NSObject, M2CCheckoutPresentationContextProviding {
    var checkoutPresentingViewController: UIViewController? { nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { ASPresentationAnchor() }
}
