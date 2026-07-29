import AuthenticationServices
import Foundation
import UIKit
import XCTest
@testable import M2CCheckout
@testable import M2CCheckoutCore

@MainActor
final class ClientTests: XCTestCase {
    func testBackendSessionReturnsCompletedAndPersistsAtExposure() async throws {
        let store = FakeResumeStore()
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: FakeBrowser(
                result: .returned(URL(string: "mygame://checkout/return?request_id=req_1")!)
            ),
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        let result = try await client.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_1",
                ttl: nil
            ),
            presentationContext: PresentationProvider()
        )

        XCTAssertEqual(result, .completed(requestID: "req_1"))
        XCTAssertTrue(store.saved)
        XCTAssertNil(store.record)
        XCTAssertEqual(client.state, .completed)
    }

    func testPendingRecoveryBlocksNewCheckoutAndRemainsIntact() async throws {
        let pending = ResumeRecord(
            requestID: "req_pending",
            integrationMode: .backend,
            sourceKind: .callback,
            statusURLTemplate: nil,
            successReturnURL: "mygame://checkout/return",
            cancelReturnURL: "mygame://checkout/cancel"
        )
        let store = FakeResumeStore()
        store.record = pending
        let client = try M2CCheckoutClient(
            config: config { _, _ in .accepted },
            transport: FakeTransport(status: .completed),
            browser: FailingBrowser(),
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_new"
                ),
                presentationContext: PresentationProvider()
            )
            XCTFail("expected pending recovery to block checkout")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        XCTAssertEqual(store.record, pending)
        XCTAssertFalse(store.saved)
    }

    func testPendingTimeoutClearsRecoveryAndAllowsNextCheckout() async throws {
        let store = FakeResumeStore()
        let time = AdvancingTestTime()
        let timedOutClient = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                returnURLs: config().returnURLs,
                statusSource: .callback { _ in .processing },
                poll: PollPolicy(timeout: 1, delays: [0])
            ),
            transport: FakeTransport(status: .processing),
            browser: FakeBrowser(
                result: .returned(
                    URL(string: "mygame://checkout/return?request_id=req_timeout")!
                )
            ),
            resumeStore: store,
            clock: time,
            sleeper: time
        )

        let timedOut = try await timedOutClient.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_timeout"
            ),
            presentationContext: PresentationProvider()
        )

        XCTAssertEqual(timedOut, .pendingTimeout(requestID: "req_timeout"))
        XCTAssertNil(store.record)

        let nextClient = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: FakeBrowser(
                result: .returned(
                    URL(string: "mygame://checkout/return?request_id=req_next")!
                )
            ),
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        let next = try await nextClient.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_next"
            ),
            presentationContext: PresentationProvider()
        )
        XCTAssertEqual(next, .completed(requestID: "req_next"))
    }

    func testLaunchFailureCanTransferToMerchantFallbackBeforeExposure() async throws {
        let client = try M2CCheckoutClient(
            config: config { _, _ in .accepted },
            transport: FakeTransport(status: .processing),
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        let result = try await client.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_2"
            ),
            presentationContext: PresentationProvider()
        )
        guard case .fallbackStarted(_, let requestID, let reason) = result else {
            return XCTFail("expected fallbackStarted")
        }
        XCTAssertEqual(requestID, "req_2")
        XCTAssertEqual(reason, .launchFailed)
    }

    func testLaunchFailureBeforeExposureClearsRecoveryWithoutFallback() async throws {
        let store = FakeResumeStore()
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .processing),
            browser: FailingBrowser(),
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_launch_failed"
                ),
                presentationContext: PresentationProvider()
            )
            XCTFail("expected launch failure")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .network)
        }
        XCTAssertNil(store.record)
    }

    func testFallbackHandlerCancellationPropagates() async throws {
        let enteredFallback = expectation(description: "fallback handler entered")
        let client = try M2CCheckoutClient(
            config: config { _, _ in
                enteredFallback.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return .accepted
            },
            transport: FakeTransport(status: .processing),
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        let task = Task {
            try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_fallback_cancelled"
                ),
                presentationContext: PresentationProvider()
            )
        }
        await fulfillment(of: [enteredFallback], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertNotEqual(client.state, .error)
        }
    }

    func testFallbackHandlerSDKErrorPreservesOriginalFailure() async throws {
        let client = try M2CCheckoutClient(
            config: config { _, _ in
                throw M2CCheckoutError(.authenticationFailed, "merchant handler failed")
            },
            transport: FakeTransport(status: .processing),
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_fallback_error"
                ),
                presentationContext: PresentationProvider()
            )
            XCTFail("expected original launch failure")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .network)
            XCTAssertEqual(error.message, "launch failed")
            XCTAssertEqual(error.fallbackStatus, .handlerOutcomeUnknown)
        }
    }

    func testColdReturnCanRecoverWithoutPersistedRecord() async throws {
        let store = FakeResumeStore()
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: FailingBrowser(),
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        M2CCheckoutClient.handleOpenURL(
            URL(string: "mygame://checkout/return?request_id=req_cold")!,
            returnURLs: config().returnURLs
        )

        let result = try await client.tryResume()

        XCTAssertEqual(result, .completed(requestID: "req_cold"))
        XCTAssertTrue(store.saved)
        XCTAssertNil(store.record)
    }

    func testStaleColdReturnDoesNotReplacePersistedRecovery() async throws {
        let store = FakeResumeStore()
        store.record = ResumeRecord(
            requestID: "req_current",
            integrationMode: .backend,
            sourceKind: .callback,
            statusURLTemplate: nil,
            successReturnURL: "mygame://checkout/return",
            cancelReturnURL: "mygame://checkout/cancel"
        )
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: FailingBrowser(),
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        XCTAssertTrue(
            M2CCheckoutClient.handleOpenURL(
                URL(string: "mygame://checkout/return?request_id=req_stale")!,
                returnURLs: config().returnURLs
            )
        )

        let result = try await client.tryResume()

        XCTAssertEqual(result, .completed(requestID: "req_current"))
        XCTAssertNil(store.record)
    }

    func testNewCheckoutIgnoresBufferedReturnFromPreviousFlow() async throws {
        M2CCheckoutClient.handleOpenURL(
            URL(string: "mygame://checkout/return?request_id=req_old")!,
            returnURLs: config().returnURLs
        )
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: BufferedReturnBrowser(
                freshReturn: URL(
                    string: "mygame://checkout/return?request_id=req_new"
                )!
            ),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        let result = try await client.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_new"
            ),
            presentationContext: PresentationProvider()
        )

        XCTAssertEqual(result, .completed(requestID: "req_new"))
    }

    func testActiveCheckoutRejectsStaleForwardedReturn() async throws {
        let browser = StaleThenCurrentForwardedBrowser(
            staleReturn: URL(
                string: "mygame://checkout/return?request_id=req_stale"
            )!,
            currentReturn: URL(
                string: "mygame://checkout/return?request_id=req_current"
            )!,
            returnURLs: config().returnURLs
        )
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: browser,
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        let result = try await client.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_current"
            ),
            presentationContext: PresentationProvider()
        )

        XCTAssertFalse(browser.staleAccepted)
        XCTAssertTrue(browser.currentAccepted)
        XCTAssertEqual(result, .completed(requestID: "req_current"))
    }

    func testDirectMismatchedBrowserReturnReconcilesCurrentRequest() async throws {
        let store = FakeResumeStore()
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: FakeBrowser(
                result: .returned(
                    URL(string: "mygame://checkout/return?request_id=req_stale")!
                )
            ),
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        let result = try await client.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_current"
            ),
            presentationContext: PresentationProvider()
        )

        XCTAssertEqual(result, .completed(requestID: "req_current"))
        XCTAssertNil(store.record)
    }

    func testReturnHandlersDeclineUnrelatedLinks() {
        ProcessCoordinator.shared.discardBufferedURLs()
        let returnURLs = config().returnURLs
        XCTAssertFalse(
            M2CCheckoutClient.handleOpenURL(
                URL(string: "mygame://profile?request_id=other")!,
                returnURLs: returnURLs
            )
        )
        XCTAssertNil(ProcessCoordinator.shared.takeBufferedURL())

        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: "https://merchant.example/account")!
        XCTAssertFalse(
            M2CCheckoutClient.handleUserActivity(activity, returnURLs: returnURLs)
        )
        XCTAssertNil(ProcessCoordinator.shared.takeBufferedURL())
    }

    func testCancellationNeverStartsMerchantFallback() async throws {
        let fallbackCalls = FallbackCallCounter()
        let config = M2CCheckoutConfig(
            publishableKey: "pub_test_example",
            returnURLs: ReturnURLs(
                success: URL(string: "mygame://checkout/return")!,
                cancel: URL(string: "mygame://checkout/cancel")!
            ),
            statusSource: .callback { _ in .completed },
            fallbackHandler: { _, _ in
                fallbackCalls.value += 1
                return .accepted
            }
        )
        let client = try M2CCheckoutClient(
            config: config,
            transport: CancelingTransport(),
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.start(
                request: AuctionRequest(transactionValue: 1),
                presentationContext: PresentationProvider()
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(fallbackCalls.value, 0)
        }
    }

    func testCancellationAfterExposureKeepsRecoveryAndBlocksSecondStart() async throws {
        let exposed = expectation(description: "browser exposed")
        let store = FakeResumeStore()
        let client = try M2CCheckoutClient(
            config: config { _, _ in .unavailable },
            transport: FakeTransport(status: .completed),
            browser: ExposedBlockingBrowser { exposed.fulfill() },
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        let first = Task {
            try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_exposed"
                ),
                presentationContext: PresentationProvider()
            )
        }
        await fulfillment(of: [exposed], timeout: 1)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }

        XCTAssertEqual(store.record?.requestID, "req_exposed")
        do {
            _ = try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_second"
                ),
                presentationContext: PresentationProvider()
            )
            XCTFail("expected pending recovery to block checkout")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(store.record?.requestID, "req_exposed")
    }

    func testCancellationBeforeExposureClearsRecovery() async throws {
        let entered = expectation(description: "browser entered")
        let store = FakeResumeStore()
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: PreExposureBlockingBrowser { entered.fulfill() },
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        let checkout = Task {
            try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_unexposed"
                ),
                presentationContext: PresentationProvider()
            )
        }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(store.record?.requestID, "req_unexposed")
        checkout.cancel()

        do {
            _ = try await checkout.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertNil(store.record)
    }

    func testCanceledLaunchFailureClearsRecoveryBeforePropagatingCancellation() async throws {
        let entered = expectation(description: "browser entered")
        let store = FakeResumeStore()
        let browser = CancellationInsensitiveFailingBrowser { entered.fulfill() }
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: browser,
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        let checkout = Task {
            try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_failed_while_canceled"
                ),
                presentationContext: PresentationProvider()
            )
        }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(store.record?.requestID, "req_failed_while_canceled")
        checkout.cancel()
        browser.failLaunch()

        do {
            _ = try await checkout.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertNil(store.record)
    }

    func testClientRequestUsesAndPersistsEffectiveReturnURLs() async throws {
        let store = FakeResumeStore()
        let success = URL(string: "override://checkout/return")!
        let cancel = URL(string: "override://checkout/cancel")!
        let browser = FakeBrowser(
            result: .returned(
                URL(string: "override://checkout/return?request_id=req_auction")!
            )
        )
        let client = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                publishableKey: "pub_test_example",
                returnURLs: ReturnURLs(
                    success: URL(string: "mygame://checkout/return")!,
                    cancel: URL(string: "mygame://checkout/cancel")!
                ),
                statusSource: .callback { _ in .completed }
            ),
            transport: FakeTransport(status: .completed),
            browser: browser,
            resumeStore: store,
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        let result = try await client.start(
            request: AuctionRequest(
                transactionValue: 1,
                successURL: success,
                cancelURL: cancel
            ),
            presentationContext: PresentationProvider()
        )

        XCTAssertEqual(result, .completed(requestID: "req_auction"))
        XCTAssertEqual(browser.callbackURL, success)
        XCTAssertEqual(store.lastSaved?.successReturnURL, success.absoluteString)
        XCTAssertEqual(store.lastSaved?.cancelReturnURL, cancel.absoluteString)
    }

    func testDismissalSurfacesNonRetryableStatusError() async throws {
        let expected = M2CCheckoutError(.authenticationFailed, "bad status credentials")
        let client = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                returnURLs: ReturnURLs(
                    success: URL(string: "mygame://checkout/return")!,
                    cancel: URL(string: "mygame://checkout/cancel")!
                ),
                statusSource: .callback { _ in throw expected }
            ),
            transport: FakeTransport(status: .processing),
            browser: FakeBrowser(result: .dismissed),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_dismissed"
                ),
                presentationContext: PresentationProvider()
            )
            XCTFail("expected authentication failure")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error, expected)
        }
    }

    func testDismissalPreservesTaskCancellation() async throws {
        let client = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                returnURLs: ReturnURLs(
                    success: URL(string: "mygame://checkout/return")!,
                    cancel: URL(string: "mygame://checkout/cancel")!
                ),
                statusSource: .callback { _ in throw CancellationError() }
            ),
            transport: FakeTransport(status: .processing),
            browser: FakeBrowser(result: .dismissed),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.start(
                session: CheckoutSession(
                    checkoutURL: URL(string: "https://vendor.example/pay")!,
                    requestID: "req_cancelled"
                ),
                presentationContext: PresentationProvider()
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
    }

    func testDismissalBoundsCancellationInsensitiveStatusCallback() async throws {
        let client = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                returnURLs: config().returnURLs,
                statusSource: .callback { _ in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                            continuation.resume()
                        }
                    }
                    return .completed
                },
                poll: PollPolicy(timeout: 0.02, delays: [0])
            ),
            transport: FakeTransport(status: .processing),
            browser: FakeBrowser(result: .dismissed),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )
        let started = Date()

        let result = try await client.start(
            session: CheckoutSession(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                requestID: "req_bounded_dismissal"
            ),
            presentationContext: PresentationProvider()
        )

        XCTAssertEqual(result, .canceled(requestID: "req_bounded_dismissal"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75)
    }

    func testCallbackFailureIsNormalized() async throws {
        let client = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                returnURLs: config().returnURLs,
                statusSource: .callback { _ in throw TestStatusCallbackError.failed }
            ),
            transport: FakeTransport(status: .processing),
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.checkStatus(requestID: "req_callback_failure")
            XCTFail("expected callback failure")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .serviceUnavailable)
            XCTAssertEqual(error.message, "status callback failed")
        }
    }

    func testBusyResumeDoesNotConsumeBufferedReturn() async throws {
        let returnURL = URL(string: "mygame://checkout/return?request_id=req_busy")!
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        XCTAssertTrue(
            M2CCheckoutClient.handleOpenURL(returnURL, returnURLs: config().returnURLs)
        )
        let client = try M2CCheckoutClient(
            config: config(),
            transport: FakeTransport(status: .completed),
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        do {
            _ = try await client.tryResume()
            XCTFail("expected active checkout rejection")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(ProcessCoordinator.shared.takeBufferedURL(), returnURL)
    }

    func testLifecycleNotificationsEndExternalBrowserWait() async throws {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        let waiting = Task { await ProcessCoordinator.shared.waitForReturn() }
        await Task.yield()

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        let returned = await waiting.value
        XCTAssertNil(returned)
    }

    func testCheckStatusCancelsInFlightURLSessionTask() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request canceled")
        BlockingURLProtocol.configure(
            onStart: { started.fulfill() },
            onStop: { stopped.fulfill() }
        )
        defer { BlockingURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingURLProtocol.self]
        let client = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                publishableKey: "pub_test_example",
                returnURLs: ReturnURLs(
                    success: URL(string: "mygame://checkout/return")!,
                    cancel: URL(string: "mygame://checkout/cancel")!
                ),
                statusSource: .m2c
            ),
            transport: CheckoutTransport(
                configuration: configuration,
                baseURL: URL(string: "https://api.example.test")!
            ),
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: FixedClock(),
            sleeper: ImmediateSleeper()
        )

        let task = Task {
            try await client.checkStatus(requestID: "req_cancel_status")
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()

        do {
            let status = try await task.value
            XCTFail("expected cancellation, got \(status)")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testTransportRejectsOversizedFixedLengthResponse() async throws {
        try await assertOversizedResponse(host: "fixed.example.test")
    }

    func testTransportRejectsOversizedChunkedResponse() async throws {
        try await assertOversizedResponse(host: "chunked.example.test")
    }

    func testMerchantStatusAcceptsStatusOnlyResponse() async throws {
        let transport = merchantStatusTransport()
        let status = try await transport.readURLStatus(
            template: "https://completed.example.test/status/{request_id}",
            requestID: "req_1"
        )
        XCTAssertEqual(status, .completed)
    }

    func testMalformedMerchantStatusFailsSafeToProcessing() async throws {
        let transport = merchantStatusTransport()
        let status = try await transport.readURLStatus(
            template: "https://malformed.example.test/status/{request_id}",
            requestID: "req_1"
        )
        XCTAssertEqual(status, .processing)
    }

    func testMerchantStatusHTTPErrorIsServiceUnavailable() async throws {
        let transport = merchantStatusTransport()
        do {
            _ = try await transport.readURLStatus(
                template: "https://missing.example.test/status/{request_id}",
                requestID: "req_1"
            )
            XCTFail("expected merchant HTTP failure")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .serviceUnavailable)
            XCTAssertEqual(error.httpStatus, 404)
        }
    }

    private func merchantStatusTransport() -> CheckoutTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MerchantStatusURLProtocol.self]
        return CheckoutTransport(configuration: configuration)
    }

    private func assertOversizedResponse(host: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedURLProtocol.self]
        let transport = CheckoutTransport(configuration: configuration)

        do {
            _ = try await transport.readURLStatus(
                template: "https://\(host)/status/{request_id}",
                requestID: "req_1"
            )
            XCTFail("expected oversized response to be rejected")
        } catch {
            XCTAssertEqual((error as? M2CCheckoutError)?.code, .unknown)
        }
    }

    func testCheckStatusBackstopPreservesCancellation() async throws {
        let started = expectation(description: "backstop started")
        let client = try M2CCheckoutClient(
            config: M2CCheckoutConfig(
                publishableKey: "pub_test_example",
                returnURLs: ReturnURLs(
                    success: URL(string: "mygame://checkout/return")!,
                    cancel: URL(string: "mygame://checkout/cancel")!
                ),
                statusSource: .callback { _ in .processing },
                statusBackstop: M2CStatusBackstop(enabled: true, threshold: 5)
            ),
            transport: BlockingStatusTransport {
                started.fulfill()
            },
            browser: FailingBrowser(),
            resumeStore: FakeResumeStore(),
            clock: ThresholdCrossingClock(),
            sleeper: ImmediateSleeper()
        )

        let task = Task {
            try await client.checkStatus(requestID: "req_backstop_cancel")
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()

        do {
            let status = try await task.value
            XCTFail("expected cancellation, got \(status)")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    private func config(
        fallback: CheckoutFallbackHandler? = nil
    ) -> M2CCheckoutConfig {
        M2CCheckoutConfig(
            returnURLs: ReturnURLs(
                success: URL(string: "mygame://checkout/return")!,
                cancel: URL(string: "mygame://checkout/cancel")!
            ),
            statusSource: .callback { _ in .completed },
            poll: PollPolicy(timeout: 1, delays: [0]),
            fallbackHandler: fallback
        )
    }
}

@MainActor
private final class FallbackCallCounter {
    var value = 0
}

private enum TestStatusCallbackError: Error {
    case failed
}

private final class FakeTransport: CheckoutTransporting, @unchecked Sendable {
    let status: ClientStatus

    init(status: ClientStatus) {
        self.status = status
    }

    func createAuction(
        request: AuctionRequest,
        returnURLs: ReturnURLs,
        publishableKey: String,
        timeout: TimeInterval
    ) async throws -> CheckoutSession {
        CheckoutSession(
            checkoutURL: URL(string: "https://vendor.example/pay")!,
            requestID: "req_auction",
            ttl: 60
        )
    }

    func readM2CStatus(requestID: String, publishableKey: String) async throws -> ClientStatus {
        status
    }

    func readURLStatus(template: String, requestID: String) async throws -> ClientStatus {
        status
    }
}

private final class CancelingTransport: CheckoutTransporting, @unchecked Sendable {
    func createAuction(
        request: AuctionRequest,
        returnURLs: ReturnURLs,
        publishableKey: String,
        timeout: TimeInterval
    ) async throws -> CheckoutSession {
        throw CancellationError()
    }

    func readM2CStatus(requestID: String, publishableKey: String) async throws -> ClientStatus {
        throw CancellationError()
    }

    func readURLStatus(template: String, requestID: String) async throws -> ClientStatus {
        throw CancellationError()
    }
}

private final class BlockingStatusTransport: CheckoutTransporting, @unchecked Sendable {
    private let onRead: @Sendable () -> Void

    init(onRead: @escaping @Sendable () -> Void) {
        self.onRead = onRead
    }

    func createAuction(
        request: AuctionRequest,
        returnURLs: ReturnURLs,
        publishableKey: String,
        timeout: TimeInterval
    ) async throws -> CheckoutSession {
        throw M2CCheckoutError(.unknown, "not used")
    }

    func readM2CStatus(requestID: String, publishableKey: String) async throws -> ClientStatus {
        onRead()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return .processing
    }

    func readURLStatus(template: String, requestID: String) async throws -> ClientStatus {
        throw M2CCheckoutError(.unknown, "not used")
    }
}

@MainActor
private final class FakeBrowser: BrowserPresenting {
    let result: BrowserOutcome
    private(set) var callbackURL: URL?

    init(result: BrowserOutcome) {
        self.result = result
    }

    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        self.callbackURL = callbackURL
        onExposed()
        return result
    }
}

@MainActor
private final class BufferedReturnBrowser: BrowserPresenting {
    private let freshReturn: URL

    init(freshReturn: URL) {
        self.freshReturn = freshReturn
    }

    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        onExposed()
        return .returned(ProcessCoordinator.shared.takeBufferedURL() ?? freshReturn)
    }
}

@MainActor
private final class StaleThenCurrentForwardedBrowser: BrowserPresenting {
    private let staleReturn: URL
    private let currentReturn: URL
    private let returnURLs: ReturnURLs
    private(set) var staleAccepted = true
    private(set) var currentAccepted = false

    init(staleReturn: URL, currentReturn: URL, returnURLs: ReturnURLs) {
        self.staleReturn = staleReturn
        self.currentReturn = currentReturn
        self.returnURLs = returnURLs
    }

    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        onExposed()
        staleAccepted = M2CCheckoutClient.handleOpenURL(
            staleReturn,
            returnURLs: returnURLs
        )
        currentAccepted = M2CCheckoutClient.handleOpenURL(
            currentReturn,
            returnURLs: returnURLs
        )
        guard let acceptedReturn = ProcessCoordinator.shared.takeBufferedURL() else {
            return .ambiguous
        }
        return .returned(acceptedReturn)
    }
}

@MainActor
private final class FailingBrowser: BrowserPresenting {
    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        throw M2CCheckoutError(.network, "launch failed")
    }
}

@MainActor
private final class ExposedBlockingBrowser: BrowserPresenting {
    private let onOpen: () -> Void

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        onExposed()
        onOpen()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return .ambiguous
    }
}

@MainActor
private final class PreExposureBlockingBrowser: BrowserPresenting {
    private let onOpen: () -> Void

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        onOpen()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return .ambiguous
    }
}

@MainActor
private final class CancellationInsensitiveFailingBrowser: BrowserPresenting {
    private let onOpen: () -> Void
    private var continuation: CheckedContinuation<Void, Never>?

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        onOpen()
        await withCheckedContinuation { self.continuation = $0 }
        throw M2CCheckoutError(.network, "launch failed")
    }

    func failLaunch() {
        continuation?.resume(returning: ())
        continuation = nil
    }
}

@MainActor
private final class FakeResumeStore: ResumeStoring {
    var record: ResumeRecord?
    var lastSaved: ResumeRecord?
    var saved = false

    func load() -> ResumeRecord? { record }
    func save(_ record: ResumeRecord) throws {
        saved = true
        self.record = record
        lastSaved = record
    }
    func clear() { record = nil }
}

private struct FixedClock: CheckoutClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private final class AdvancingTestTime: CheckoutClock, CheckoutSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: seconds)
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

private final class ThresholdCrossingClock: CheckoutClock, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    func now() -> Date {
        lock.lock()
        defer {
            reads += 1
            lock.unlock()
        }
        return Date(timeIntervalSince1970: 1_700_000_000 + (reads == 0 ? 0 : 10))
    }
}

private struct ImmediateSleeper: CheckoutSleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

private final class BlockingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var onStart: (() -> Void)?
    private static var onStop: (() -> Void)?

    static func configure(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        lock.lock()
        self.onStart = onStart
        self.onStop = onStop
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        onStart = nil
        onStop = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.onStart
        Self.lock.unlock()
        handler?()
    }

    override func stopLoading() {
        Self.lock.lock()
        let handler = Self.onStop
        Self.lock.unlock()
        handler?()
    }
}

private final class OversizedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data(repeating: 120, count: maximumResponseBodyBytes + 1)
        var headers: [String: String] = ["Content-Type": "application/json"]
        if request.url?.host == "fixed.example.test" {
            headers["Content-Length"] = String(body.count)
        } else {
            headers["Transfer-Encoding"] = "chunked"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MerchantStatusURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host
        let statusCode = host == "missing.example.test" ? 404 : 200
        let body: Data
        switch host {
        case "completed.example.test":
            body = Data(#"{"status":"completed"}"#.utf8)
        case "malformed.example.test":
            body = Data("{".utf8)
        default:
            body = Data()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class PresentationProvider: NSObject,
    M2CCheckoutPresentationContextProviding {
    let checkoutPresentingViewController: UIViewController? = UIViewController()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
