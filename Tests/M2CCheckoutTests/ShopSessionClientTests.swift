import Foundation
import SafariServices
import UIKit
import XCTest
@testable import M2CCheckout
@testable import M2CCheckoutCore

@MainActor
final class ShopSessionClientTests: XCTestCase {
    private let sessionID = "550e8400-e29b-41d4-a716-446655440000"
    private let shopURL = URL(string: "https://vendor.example/shop")!

    func testCreateLaunchForwardsInputsAndReturnsServerHandle() async throws {
        let request = ShopSessionRequest(
            currency: "USD",
            language: "en-US",
            segments: ["returning"],
            returnURL: URL(string: "mygame://shop/closed")
        )
        let created = createdSession()
        let transport = RecordingShopSessionTransport(created: created)
        let browser = RecordingShopBrowser()
        let client = try M2CShopSessionClient(
            config: M2CSessionConfig(
                publishableKey: "pub_test_session",
                browserMode: .inAppPersistent
            ),
            transport: transport,
            browser: browser,
            clock: FixedShopSessionClock()
        )
        let presenter = UIViewController()

        let handle = try await client.startShopSession(request, from: presenter)

        XCTAssertEqual(transport.createCalls, 1)
        XCTAssertEqual(transport.request, request)
        XCTAssertEqual(transport.publishableKey, "pub_test_session")
        XCTAssertEqual(browser.prepareCalls, 1)
        XCTAssertEqual(browser.launchCalls, 1)
        XCTAssertEqual(browser.shopURL, created.shopURL)
        XCTAssertEqual(browser.returnURL, request.returnURL)
        XCTAssertEqual(browser.mode, .inAppPersistent)
        XCTAssertTrue(browser.presenter === presenter)
        XCTAssertEqual(handle.sessionID, created.sessionID)
        XCTAssertEqual(handle.sessionExpiresAt, created.sessionExpiresAt)
        XCTAssertEqual(handle.shopURLExpiresAt, created.shopURLExpiresAt)
        XCTAssertEqual(handle.shopURL, created.shopURL)
    }

    func testUnavailablePresenterFailsBeforeSessionCreation() async throws {
        let transport = RecordingShopSessionTransport(created: createdSession())
        let client = try M2CShopSessionClient(
            config: M2CSessionConfig(
                publishableKey: "pub_test_session",
                browserMode: .inAppPreferred
            ),
            transport: transport,
            browser: SystemShopSessionBrowserPresenter(
                safariPresentationDriver: RecordingShopSafariPresentationDriver()
            ),
            clock: FixedShopSessionClock()
        )

        do {
            _ = try await client.startShopSession(
                ShopSessionRequest(currency: "USD"),
                from: UIViewController()
            )
            XCTFail("expected unavailable presenter to fail")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(transport.createCalls, 0)
    }

    func testTransitioningPresenterFailsBeforeSessionCreation() async throws {
        let host = DismissingViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let transport = RecordingShopSessionTransport(created: createdSession())
        let client = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: transport,
            browser: SystemShopSessionBrowserPresenter(
                safariPresentationDriver: RecordingShopSafariPresentationDriver()
            ),
            clock: FixedShopSessionClock()
        )

        do {
            _ = try await client.startShopSession(
                ShopSessionRequest(currency: "USD"),
                from: host
            )
            XCTFail("expected transitioning presenter to fail")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(transport.createCalls, 0)
    }

    func testRefusedPresentationFailsAndReleasesGlobalState() async throws {
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let refusedDriver = RecordingShopSafariPresentationDriver(
            completesPresentationAutomatically: false,
            acceptsPresentation: false
        )
        let refusedClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: RecordingShopSessionTransport(created: createdSession()),
            browser: SystemShopSessionBrowserPresenter(
                safariPresentationDriver: refusedDriver
            ),
            clock: FixedShopSessionClock()
        )

        do {
            _ = try await refusedClient.startShopSession(
                ShopSessionRequest(currency: "USD"),
                from: host
            )
            XCTFail("expected refused presentation to fail")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertFalse(refusedDriver.isPresented)

        let returnURL = URL(string: "mygame://shop/closed")!
        let nextClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: RecordingShopSessionTransport(created: createdSession()),
            browser: SystemShopSessionBrowserPresenter(
                safariPresentationDriver: RecordingShopSafariPresentationDriver()
            ),
            clock: FixedShopSessionClock()
        )
        _ = try await nextClient.startShopSession(
            ShopSessionRequest(currency: "USD", returnURL: returnURL),
            from: host
        )
        XCTAssertTrue(M2CShopSessionClient.handleOpenURL(returnURL))
    }

    func testOffscreenPresentationIsReleasedBeforeNextLaunch() async throws {
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let firstDriver = RecordingShopSafariPresentationDriver()
        let firstBrowser = SystemShopSessionBrowserPresenter(
            safariPresentationDriver: firstDriver
        )
        let firstClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: RecordingShopSessionTransport(created: createdSession()),
            browser: firstBrowser,
            clock: FixedShopSessionClock()
        )
        _ = try await firstClient.startShopSession(
            ShopSessionRequest(currency: "USD"),
            from: host
        )
        let firstController = try XCTUnwrap(firstDriver.capturedViewController)
        defer { firstBrowser.safariViewControllerDidFinish(firstController) }
        firstDriver.recordExternalDismissal()

        let returnURL = URL(string: "mygame://shop/next-closed")!
        defer { _ = M2CShopSessionClient.handleOpenURL(returnURL) }
        let nextClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: RecordingShopSessionTransport(created: createdSession()),
            browser: SystemShopSessionBrowserPresenter(
                safariPresentationDriver: RecordingShopSafariPresentationDriver()
            ),
            clock: FixedShopSessionClock()
        )
        _ = try await nextClient.startShopSession(
            ShopSessionRequest(currency: "USD", returnURL: returnURL),
            from: host
        )

        XCTAssertNil(firstController.delegate)
        XCTAssertTrue(M2CShopSessionClient.handleOpenURL(returnURL))
    }

    func testMatchingReturnDismissesOnlyActiveInAppShopPresentation() async throws {
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let expectedReturn = URL(string: "mygame://shop/closed")!
        let driver = RecordingShopSafariPresentationDriver()
        let browser = SystemShopSessionBrowserPresenter(safariPresentationDriver: driver)
        try await browser.launch(
            shopURL: shopURL,
            returnURL: expectedReturn,
            mode: .inAppPreferred,
            presenter: host
        )
        defer { _ = M2CShopSessionClient.handleOpenURL(expectedReturn) }
        let controller = try XCTUnwrap(driver.capturedViewController)

        XCTAssertTrue(driver.isPresented)
        XCTAssertFalse(
            M2CShopSessionClient.handleOpenURL(URL(string: "mygame://checkout/return")!)
        )
        XCTAssertTrue(driver.isPresented)
        XCTAssertTrue(
            M2CShopSessionClient.handleOpenURL(
                URL(string: "mygame://shop/closed?source=vendor")!
            )
        )
        XCTAssertFalse(driver.isPresented)
        XCTAssertNil(controller.delegate)
        XCTAssertFalse(M2CShopSessionClient.handleOpenURL(expectedReturn))
    }

    func testSafariDoneClearsLivePresentationBeforeNextLaunch() async throws {
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let firstReturn = URL(string: "mygame://shop/first-closed")!
        defer { _ = M2CShopSessionClient.handleOpenURL(firstReturn) }
        let firstDriver = RecordingShopSafariPresentationDriver()
        let firstBrowser = SystemShopSessionBrowserPresenter(
            safariPresentationDriver: firstDriver
        )
        try await firstBrowser.launch(
            shopURL: shopURL,
            returnURL: firstReturn,
            mode: .inAppPreferred,
            presenter: host
        )
        let firstController = try XCTUnwrap(firstDriver.capturedViewController)
        XCTAssertTrue(firstDriver.isPresented)

        firstBrowser.safariViewControllerDidFinish(firstController)

        XCTAssertNil(firstController.delegate)
        XCTAssertFalse(M2CShopSessionClient.handleOpenURL(firstReturn))

        let nextReturn = URL(string: "mygame://shop/next-closed")!
        defer { _ = M2CShopSessionClient.handleOpenURL(nextReturn) }
        let nextDriver = RecordingShopSafariPresentationDriver()
        let nextBrowser = SystemShopSessionBrowserPresenter(
            safariPresentationDriver: nextDriver
        )
        try await nextBrowser.launch(
            shopURL: shopURL,
            returnURL: nextReturn,
            mode: .inAppPreferred,
            presenter: host
        )

        XCTAssertTrue(nextDriver.isPresented)
        XCTAssertTrue(M2CShopSessionClient.handleOpenURL(nextReturn))
    }

    func testMatchingReturnDuringPresentationDismissesAfterCompletion() async throws {
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let expectedReturn = URL(string: "mygame://shop/closed")!
        let presentationStarted = expectation(description: "shop presentation started")
        let driver = RecordingShopSafariPresentationDriver(
            completesPresentationAutomatically: false,
            onPresent: { presentationStarted.fulfill() }
        )
        let browser = SystemShopSessionBrowserPresenter(safariPresentationDriver: driver)
        let launch = Task {
            try await browser.launch(
                shopURL: shopURL,
                returnURL: expectedReturn,
                mode: .inAppPreferred,
                presenter: host
            )
        }
        await fulfillment(of: [presentationStarted], timeout: 1)

        XCTAssertTrue(M2CShopSessionClient.handleOpenURL(expectedReturn))
        XCTAssertTrue(driver.isPresented)

        driver.completePresentation()
        try await launch.value
        XCTAssertFalse(driver.isPresented)
        XCTAssertFalse(M2CShopSessionClient.handleOpenURL(expectedReturn))
    }

    func testCancellationDuringSuccessfulBrowserHandoffReturnsHandle() async throws {
        let launchStarted = expectation(description: "shop browser launch started")
        let browser = CancellationInsensitiveShopBrowser {
            launchStarted.fulfill()
        }
        let client = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: RecordingShopSessionTransport(created: createdSession()),
            browser: browser,
            clock: FixedShopSessionClock()
        )

        let task = Task {
            try await client.startShopSession(ShopSessionRequest(currency: "USD"))
        }
        await fulfillment(of: [launchStarted], timeout: 1)
        task.cancel()
        browser.completeLaunch()

        let handle = try await task.value
        XCTAssertEqual(handle.sessionID, sessionID)
        XCTAssertEqual(handle.shopURL, shopURL)
    }

    func testTTLExpiryPreventsLaunchAndReleasesCoordinator() async throws {
        let expired = CreatedShopSession(
            sessionID: sessionID,
            sessionExpiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            shopURLExpiresAt: Date(timeIntervalSince1970: 1_700_000_300),
            shopURL: shopURL,
            ttl: 60
        )
        let expiredBrowser = RecordingShopBrowser()
        let expiredClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: RecordingShopSessionTransport(created: expired),
            browser: expiredBrowser,
            clock: SequenceShopSessionClock([0, 60])
        )

        do {
            _ = try await expiredClient.startShopSession(ShopSessionRequest(currency: "USD"))
            XCTFail("expected shop URL expiry")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .checkoutExpired)
        }
        XCTAssertEqual(expiredBrowser.launchCalls, 0)

        let nextBrowser = RecordingShopBrowser()
        let nextClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: RecordingShopSessionTransport(created: createdSession()),
            browser: nextBrowser,
            clock: FixedShopSessionClock()
        )
        let next = try await nextClient.startShopSession(ShopSessionRequest(currency: "USD"))
        XCTAssertEqual(next.sessionID, sessionID)
        XCTAssertEqual(nextBrowser.launchCalls, 1)
    }

    func testConcurrentStartIsRejectedWhileStatusReadRemainsIndependent() async throws {
        let launchStarted = expectation(description: "first shop browser launch started")
        let browser = CancellationInsensitiveShopBrowser {
            launchStarted.fulfill()
        }
        let firstTransport = RecordingShopSessionTransport(created: createdSession())
        let firstClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: firstTransport,
            browser: browser,
            clock: FixedShopSessionClock()
        )
        let secondTransport = RecordingShopSessionTransport(created: createdSession())
        let secondClient = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: secondTransport,
            browser: RecordingShopBrowser(),
            clock: FixedShopSessionClock()
        )
        let first = Task {
            try await firstClient.startShopSession(ShopSessionRequest(currency: "USD"))
        }
        await fulfillment(of: [launchStarted], timeout: 1)

        do {
            _ = try await secondClient.startShopSession(ShopSessionRequest(currency: "USD"))
            XCTFail("expected concurrent start to fail")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(secondTransport.createCalls, 0)

        let status = try await firstClient.readShopSessionStatus(sessionID: sessionID.uppercased())
        XCTAssertEqual(status.status, .active)
        XCTAssertEqual(firstTransport.statusCalls, 1)
        XCTAssertEqual(firstTransport.statusSessionID, sessionID)

        browser.completeLaunch()
        let firstHandle = try await first.value
        XCTAssertEqual(firstHandle.sessionID, sessionID)
    }

    func testInvalidRequestAndMalformedStatusIDFailBeforeTransport() async throws {
        let transport = RecordingShopSessionTransport(created: createdSession())
        let client = try M2CShopSessionClient(
            config: M2CSessionConfig(publishableKey: "pub_test_session"),
            transport: transport,
            browser: RecordingShopBrowser(),
            clock: FixedShopSessionClock()
        )

        do {
            _ = try await client.startShopSession(ShopSessionRequest(currency: ""))
            XCTFail("expected invalid request")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(transport.createCalls, 0)

        do {
            _ = try await client.readShopSessionStatus(sessionID: "not-a-session-id")
            XCTFail("expected invalid session ID")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(transport.statusCalls, 0)
    }

    func testHTTPTransportSendsSessionContractAndUsesServerDeadlines() async throws {
        ShopSessionURLProtocol.configure(statusCode: 200)
        defer { ShopSessionURLProtocol.reset() }
        let transport = shopSessionHTTPTransport()
        let request = ShopSessionRequest(
            currency: "USD",
            language: "en-US",
            segments: ["returning", "vip"],
            returnURL: URL(string: "mygame://shop/closed")
        )

        let created = try await transport.createSession(
            request: request,
            publishableKey: "pub_test_session"
        )
        let captured = try XCTUnwrap(ShopSessionURLProtocol.capturedRequest())
        let data = try XCTUnwrap(ShopSessionURLProtocol.capturedBody())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/v1/session")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-API-Key"), "pub_test_session")
        XCTAssertEqual(body["device_type"] as? String, "mobile")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["currency"] as? String, "USD")
        XCTAssertEqual(body["language"] as? String, "en-US")
        XCTAssertEqual(body["segments"] as? [String], ["returning", "vip"])
        XCTAssertEqual(body["return_url"] as? String, "mygame://shop/closed")
        XCTAssertEqual(created.sessionID, sessionID)
        XCTAssertEqual(created.sessionExpiresAt, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(created.shopURLExpiresAt, Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertEqual(created.shopURL, shopURL)
        XCTAssertEqual(created.ttl, 300)
        XCTAssertEqual(ShopSessionURLProtocol.requestCount(), 1)
    }

    func testHTTPTransportAcceptsSupportedTimestampPrecisions() async throws {
        defer { ShopSessionURLProtocol.reset() }
        let cases: [(String, TimeInterval)] = [
            ("2023-11-14T23:13:20Z", 1_700_003_600),
            ("2023-11-14T23:13:20.123Z", 1_700_003_600.123),
            ("2023-11-14T23:13:20.123456Z", 1_700_003_600.123),
            ("2023-11-14T23:13:20.123456789Z", 1_700_003_600.123),
        ]
        for (timestamp, expectedSeconds) in cases {
            ShopSessionURLProtocol.configure(
                statusCode: 200,
                body: shopSessionResponseBody(
                    expiresAt: timestamp,
                    launchExpiresAt: timestamp
                )
            )
            let created = try await shopSessionHTTPTransport().createSession(
                request: ShopSessionRequest(currency: "USD"),
                publishableKey: "pub_test_session"
            )
            XCTAssertEqual(
                created.sessionExpiresAt.timeIntervalSince1970,
                expectedSeconds,
                accuracy: 0.001
            )
            XCTAssertEqual(
                created.shopURLExpiresAt.timeIntervalSince1970,
                expectedSeconds,
                accuracy: 0.001
            )
        }
    }

    func testHTTPTransportRejectsMalformedSuccessfulResponses() async throws {
        defer { ShopSessionURLProtocol.reset() }
        let cases: [(String, Data)] = [
            ("ttl below minimum", shopSessionResponseBody(ttl: 59)),
            ("ttl above maximum", shopSessionResponseBody(ttl: 3_601)),
            (
                "non-https shop URL",
                shopSessionResponseBody(shopURL: "http://vendor.example/shop")
            ),
            ("malformed session ID", shopSessionResponseBody(sessionID: "not-a-session-id")),
            ("malformed session expiry", shopSessionResponseBody(expiresAt: "not-a-date")),
            ("malformed launch expiry", shopSessionResponseBody(launchExpiresAt: "not-a-date")),
        ]
        for (name, body) in cases {
            ShopSessionURLProtocol.configure(statusCode: 200, body: body)
            do {
                _ = try await shopSessionHTTPTransport().createSession(
                    request: ShopSessionRequest(currency: "USD"),
                    publishableKey: "pub_test_session"
                )
                XCTFail("expected malformed response to fail: \(name)")
            } catch let error as M2CCheckoutError {
                XCTAssertEqual(error.code, .unknown, name)
            }
            XCTAssertEqual(ShopSessionURLProtocol.requestCount(), 1, name)
        }
    }

    func testHTTPTransportMapsCreationErrorsWithoutRetrying() async throws {
        let cases: [(Int, M2CCheckoutErrorCode)] = [
            (400, .invalidRequest),
            (401, .authenticationFailed),
            (403, .originNotAllowed),
            (404, .noVendorsAvailable),
            (409, .invalidRequest),
            (429, .rateLimited),
            (503, .serviceUnavailable),
            (422, .unknown),
        ]

        for (statusCode, expectedCode) in cases {
            ShopSessionURLProtocol.configure(
                statusCode: statusCode,
                body: Data(#"{"error":"request rejected"}"#.utf8),
                retryAfter: "7"
            )
            let transport = shopSessionHTTPTransport()
            do {
                _ = try await transport.createSession(
                    request: ShopSessionRequest(currency: "USD"),
                    publishableKey: "pub_test_session"
                )
                XCTFail("expected HTTP \(statusCode) to fail")
            } catch let error as M2CCheckoutError {
                XCTAssertEqual(error.code, expectedCode, "HTTP \(statusCode)")
                XCTAssertEqual(error.httpStatus, statusCode, "HTTP \(statusCode)")
                if statusCode == 429 || statusCode == 503 {
                    XCTAssertEqual(error.retryAfter, 7, "HTTP \(statusCode)")
                }
            }
            XCTAssertEqual(ShopSessionURLProtocol.requestCount(), 1, "HTTP \(statusCode)")
        }
        ShopSessionURLProtocol.reset()
    }

    func testHTTPStatusReadMaps404AndMakesOneCanonicalRequest() async throws {
        ShopSessionURLProtocol.configure(
            statusCode: 404,
            body: Data(#"{"error":"not found"}"#.utf8)
        )
        defer { ShopSessionURLProtocol.reset() }
        let transport = shopSessionHTTPTransport()

        do {
            _ = try await transport.readSessionStatus(
                sessionID: sessionID.uppercased(),
                publishableKey: "pub_test_session"
            )
            XCTFail("expected missing session")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .sessionNotFound)
            XCTAssertEqual(error.httpStatus, 404)
        }

        let captured = try XCTUnwrap(ShopSessionURLProtocol.capturedRequest())
        let components = try XCTUnwrap(
            URLComponents(url: captured.url!, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.path, "/api/v1/session-status")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "session_id", value: sessionID)])
        XCTAssertEqual(ShopSessionURLProtocol.requestCount(), 1)
    }

    private func shopSessionHTTPTransport() -> CheckoutTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShopSessionURLProtocol.self]
        return CheckoutTransport(
            configuration: configuration,
            baseURL: URL(string: "https://api.example.test")!
        )
    }

    private func shopSessionResponseBody(
        sessionID: String = "550e8400-e29b-41d4-a716-446655440000",
        expiresAt: String = "2023-11-14T23:13:20Z",
        shopURL: String = "https://vendor.example/shop",
        ttl: Int = 300,
        launchExpiresAt: String = "2023-11-14T22:18:20Z"
    ) -> Data {
        Data(
            """
            {"session_id":"\(sessionID)","expires_at":"\(expiresAt)","winner":{"shop_url":"\(shopURL)","ttl":\(ttl),"launch_expires_at":"\(launchExpiresAt)"}}
            """.utf8
        )
    }

    private func createdSession() -> CreatedShopSession {
        CreatedShopSession(
            sessionID: sessionID,
            sessionExpiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            shopURLExpiresAt: Date(timeIntervalSince1970: 1_700_000_300),
            shopURL: shopURL,
            ttl: 300
        )
    }
}

private final class RecordingShopSessionTransport: CheckoutTransporting, @unchecked Sendable {
    private let created: CreatedShopSession
    private(set) var createCalls = 0
    private(set) var request: ShopSessionRequest?
    private(set) var publishableKey: String?
    private(set) var statusCalls = 0
    private(set) var statusSessionID: String?

    init(created: CreatedShopSession) {
        self.created = created
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
        throw M2CCheckoutError(.unknown, "not used")
    }

    func readURLStatus(template: String, requestID: String) async throws -> ClientStatus {
        throw M2CCheckoutError(.unknown, "not used")
    }

    func createSession(
        request: ShopSessionRequest,
        publishableKey: String
    ) async throws -> CreatedShopSession {
        createCalls += 1
        self.request = request
        self.publishableKey = publishableKey
        return created
    }

    func readSessionStatus(
        sessionID: String,
        publishableKey: String
    ) async throws -> ShopSessionStatus {
        statusCalls += 1
        statusSessionID = sessionID
        self.publishableKey = publishableKey
        return ShopSessionStatus(
            sessionID: sessionID,
            status: .active,
            completedPurchases: 2
        )
    }
}

@MainActor
private final class RecordingShopBrowser: ShopSessionBrowserPresenting {
    private(set) var prepareCalls = 0
    private(set) var launchCalls = 0
    private(set) var shopURL: URL?
    private(set) var returnURL: URL?
    private(set) var mode: BrowserMode?
    private(set) weak var presenter: UIViewController?

    func prepareLaunch(
        mode: BrowserMode,
        presenter: UIViewController?
    ) throws {
        prepareCalls += 1
    }

    func launch(
        shopURL: URL,
        returnURL: URL?,
        mode: BrowserMode,
        presenter: UIViewController?
    ) async throws {
        launchCalls += 1
        self.shopURL = shopURL
        self.returnURL = returnURL
        self.mode = mode
        self.presenter = presenter
    }
}

@MainActor
private final class CancellationInsensitiveShopBrowser: ShopSessionBrowserPresenting {
    private let onLaunch: () -> Void
    private var continuation: CheckedContinuation<Void, Never>?

    init(onLaunch: @escaping () -> Void) {
        self.onLaunch = onLaunch
    }

    func prepareLaunch(
        mode: BrowserMode,
        presenter: UIViewController?
    ) throws {}

    func launch(
        shopURL: URL,
        returnURL: URL?,
        mode: BrowserMode,
        presenter: UIViewController?
    ) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onLaunch()
        }
    }

    func completeLaunch() {
        continuation?.resume(returning: ())
        continuation = nil
    }
}

@MainActor
private final class RecordingShopSafariPresentationDriver: SafariPresentationDriving {
    private(set) var capturedViewController: SFSafariViewController?
    private(set) var isPresented = false
    private let completesPresentationAutomatically: Bool
    private let acceptsPresentation: Bool
    private let onPresent: (() -> Void)?
    private var presentationCompletion: (() -> Void)?

    init(
        completesPresentationAutomatically: Bool = true,
        acceptsPresentation: Bool = true,
        onPresent: (() -> Void)? = nil
    ) {
        self.completesPresentationAutomatically = completesPresentationAutomatically
        self.acceptsPresentation = acceptsPresentation
        self.onPresent = onPresent
    }

    func present(
        _ controller: SFSafariViewController,
        from host: UIViewController,
        completion: @escaping () -> Void
    ) {
        capturedViewController = controller
        isPresented = acceptsPresentation
        onPresent?()
        if completesPresentationAutomatically && acceptsPresentation {
            completion()
        } else if acceptsPresentation {
            presentationCompletion = completion
        }
    }

    func completePresentation() {
        let completion = presentationCompletion
        presentationCompletion = nil
        completion?()
    }

    func recordExternalDismissal() {
        isPresented = false
    }

    func dismiss(
        _ controller: SFSafariViewController,
        animated: Bool,
        completion: (() -> Void)?
    ) {
        XCTAssertTrue(controller === capturedViewController)
        isPresented = false
        completion?()
    }

    func isPresentationActive(
        _ controller: SFSafariViewController,
        from host: UIViewController
    ) -> Bool {
        isPresented && controller === capturedViewController
    }
}

@MainActor
private final class DismissingViewController: UIViewController {
    override var isBeingDismissed: Bool { true }
}

private struct FixedShopSessionClock: ShopSessionClock {
    func now() -> TimeInterval { 1_000 }
}

private final class SequenceShopSessionClock: ShopSessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(_ values: [TimeInterval]) {
        self.values = values
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class ShopSessionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var configuredStatusCode = 200
    private static var configuredBody: Data?
    private static var configuredRetryAfter: String?
    private static var lastRequest: URLRequest?
    private static var lastBody: Data?
    private static var requests = 0

    static func configure(
        statusCode: Int,
        body: Data? = nil,
        retryAfter: String? = nil
    ) {
        lock.lock()
        configuredStatusCode = statusCode
        configuredBody = body
        configuredRetryAfter = retryAfter
        lastRequest = nil
        lastBody = nil
        requests = 0
        lock.unlock()
    }

    static func reset() {
        configure(statusCode: 200)
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func capturedBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastBody
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestBody = request.httpBody ?? Self.read(stream: request.httpBodyStream)
        Self.lock.lock()
        Self.lastRequest = request
        Self.lastBody = requestBody
        Self.requests += 1
        let statusCode = Self.configuredStatusCode
        let configuredBody = Self.configuredBody
        let retryAfter = Self.configuredRetryAfter
        Self.lock.unlock()

        let body = configuredBody ?? Self.successBody(for: request)
        var headers = ["Content-Length": String(body.count)]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func successBody(for request: URLRequest) -> Data {
        if request.url?.path == "/api/v1/session-status" {
            return Data(
                #"{"session_id":"550e8400-e29b-41d4-a716-446655440000","status":"active","completed_purchases":2}"#.utf8
            )
        }
        return Data(
            #"{"session_id":"550e8400-e29b-41d4-a716-446655440000","expires_at":"2023-11-14T23:13:20Z","winner":{"shop_url":"https://vendor.example/shop","ttl":300,"launch_expires_at":"2023-11-14T22:18:20Z"}}"#.utf8
        )
    }

    private static func read(stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
