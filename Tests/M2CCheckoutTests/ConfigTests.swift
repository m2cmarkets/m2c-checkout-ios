import AuthenticationServices
import Foundation
import SafariServices
import UIKit
import XCTest
@testable import M2CCheckout

@MainActor
final class ConfigTests: XCTestCase {
    private let returns = ReturnURLs(
        success: URL(string: "mygame://checkout/return")!,
        cancel: URL(string: "mygame://checkout/cancel")!
    )

    func testM2CStatusRequiresPublishableKey() {
        XCTAssertThrowsError(
            try M2CCheckoutClient(
                config: .init(returnURLs: returns, statusSource: .m2c)
            )
        )
    }

    func testURLStatusAcceptsBackendModeWithoutKey() {
        XCTAssertNoThrow(
            try M2CCheckoutClient(
                config: .init(
                    returnURLs: returns,
                    statusSource: .url(template: "https://merchant.example/status/{request_id}")
                )
            )
        )
    }

    func testSubscribeIsExplicitlyRejected() {
        XCTAssertThrowsError(
            try M2CCheckoutClient(
                config: .init(returnURLs: returns, statusSource: .subscribe)
            )
        )
    }

    func testUnsafePollPoliciesAreRejected() {
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
            XCTAssertThrowsError(
                try M2CCheckoutClient(
                    config: .init(
                        returnURLs: returns,
                        statusSource: .callback { _ in .processing },
                        poll: policy
                    )
                )
            ) { error in
                XCTAssertEqual((error as? M2CCheckoutError)?.code, .invalidRequest)
            }
        }
    }

    func testAmbiguousReturnURLsAreRejected() {
        let pairs = [
            ReturnURLs(
                success: URL(string: "mygame://checkout/return?outcome=success")!,
                cancel: URL(string: "mygame://checkout/return?outcome=cancel")!
            ),
            ReturnURLs(
                success: URL(string: "mygame://checkout/return/complete")!,
                cancel: URL(string: "mygame://checkout/return")!
            )
        ]
        for pair in pairs {
            XCTAssertThrowsError(
                try M2CCheckoutClient(
                    config: .init(returnURLs: pair, statusSource: .callback { _ in .processing })
                )
            )
        }
    }

    func testPersistentModeRequiresOneCustomReturnScheme() {
        XCTAssertThrowsError(
            try M2CCheckoutClient(
                config: .init(
                    returnURLs: ReturnURLs(
                        success: URL(string: "success-app://checkout/return")!,
                        cancel: URL(string: "cancel-app://checkout/cancel")!
                    ),
                    statusSource: .callback { _ in .processing },
                    browserMode: .inAppPersistent
                )
            )
        )
    }

    func testPresentationRoutesCoverEveryModeAndReturnType() {
        let httpsReturn = URL(string: "https://merchant.example/checkout/return")!
        let customReturn = URL(string: "mygame://checkout/return")!

        XCTAssertEqual(
            browserPresentationRoute(
                callbackURL: httpsReturn,
                mode: .inAppPreferred
            ),
            .external
        )
        XCTAssertEqual(
            browserPresentationRoute(
                callbackURL: customReturn,
                mode: .inAppPreferred
            ),
            .authenticationSession
        )
        XCTAssertEqual(
            browserPresentationRoute(
                callbackURL: httpsReturn,
                mode: .inAppPersistent
            ),
            .safariViewController
        )
        XCTAssertEqual(
            browserPresentationRoute(
                callbackURL: customReturn,
                mode: .inAppPersistent
            ),
            .safariViewController
        )
        XCTAssertEqual(
            browserPresentationRoute(
                callbackURL: customReturn,
                mode: .externalBrowser
            ),
            .external
        )
    }

    func testPersistentPresentationRejectsMissingVisibleHost() async {
        let presenter = SystemBrowserPresenter()
        do {
            _ = try await presenter.open(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                callbackURL: URL(string: "mygame://checkout/return")!,
                mode: .inAppPersistent,
                presentationContext: DetachedPresentationProvider(),
                onExposed: {}
            )
            XCTFail("expected presentation failure")
        } catch let error as M2CCheckoutError {
            XCTAssertEqual(error.code, .invalidRequest)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPersistentPresentationReconcilesSafariDismissalRace() async throws {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }

        let presentation = await startPersistentPresentation(
            callbackURL: URL(string: "mygame://checkout/return")!
        )
        defer { presentation.window.isHidden = true }
        let safari = try XCTUnwrap(
            presentation.driver.capturedViewController
        )
        presentation.driver.recordUserDismissal()
        presentation.presenter.safariViewControllerDidFinish(safari)

        switch try await presentation.result.value {
        case .ambiguous:
            break
        case .returned, .dismissed:
            XCTFail("Safari dismissal must reconcile the return race")
        }
        XCTAssertNil(safari.delegate)
        XCTAssertFalse(presentation.driver.isPresented)
    }

    func testPersistentPresentationReceivesCustomSchemeReturn() async throws {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        let returns = ReturnURLs(
            success: URL(string: "mygame://checkout/return")!,
            cancel: URL(string: "mygame://checkout/cancel")!
        )
        let returnedURL = URL(
            string: "mygame://checkout/return?request_id=req_custom_presenter"
        )!
        ProcessCoordinator.shared.bindReturn(
            requestID: "req_custom_presenter",
            returnURLs: returns
        )
        let presentation = await startPersistentPresentation(callbackURL: returns.success)
        defer { presentation.window.isHidden = true }
        let safari = try XCTUnwrap(
            presentation.driver.capturedViewController
        )

        XCTAssertTrue(M2CCheckoutClient.handleOpenURL(returnedURL, returnURLs: returns))
        switch try await presentation.result.value {
        case .returned(let url):
            XCTAssertEqual(url, returnedURL)
        case .dismissed, .ambiguous:
            XCTFail("expected custom-scheme return")
        }
        XCTAssertNil(safari.delegate)
        XCTAssertFalse(presentation.driver.isPresented)
    }

    func testPersistentPresentationReceivesUniversalLinkReturn() async throws {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        let returns = ReturnURLs(
            success: URL(string: "https://merchant.example/checkout/return")!,
            cancel: URL(string: "https://merchant.example/checkout/cancel")!
        )
        let returnedURL = URL(
            string: "https://merchant.example/checkout/return?request_id=req_link_presenter"
        )!
        ProcessCoordinator.shared.bindReturn(
            requestID: "req_link_presenter",
            returnURLs: returns
        )
        let presentation = await startPersistentPresentation(callbackURL: returns.success)
        defer { presentation.window.isHidden = true }
        let safari = try XCTUnwrap(
            presentation.driver.capturedViewController
        )
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = returnedURL

        XCTAssertTrue(M2CCheckoutClient.handleUserActivity(activity, returnURLs: returns))
        switch try await presentation.result.value {
        case .returned(let url):
            XCTAssertEqual(url, returnedURL)
        case .dismissed, .ambiguous:
            XCTFail("expected Universal Link return")
        }
        XCTAssertNil(safari.delegate)
        XCTAssertFalse(presentation.driver.isPresented)
    }

    func testPersistentPresentationCancellationSettlesAndReleasesDelegate() async throws {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        let presentation = await startPersistentPresentation(
            callbackURL: URL(string: "mygame://checkout/return")!
        )
        defer { presentation.window.isHidden = true }
        let safari = try XCTUnwrap(
            presentation.driver.capturedViewController
        )

        presentation.result.cancel()
        do {
            _ = try await presentation.result.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertNil(safari.delegate)
        XCTAssertFalse(presentation.driver.isPresented)
    }

    func testPersistentPresentationCancellationSettlesWhenExposureCallbackStalls() async throws {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }

        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let attempted = expectation(description: "Safari presentation attempted")
        let driver = TestSafariPresentationDriver(completesPresentation: false)
        driver.onPresentationAttempted = { attempted.fulfill() }
        let presenter = SystemBrowserPresenter(safariPresentationDriver: driver)
        let result = Task { @MainActor in
            try await presenter.open(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                callbackURL: URL(string: "mygame://checkout/return")!,
                mode: .inAppPersistent,
                presentationContext: AttachedPresentationProvider(host: host),
                onExposed: { XCTFail("stalled presentation must not be exposed") }
            )
        }
        defer { result.cancel() }
        await fulfillment(of: [attempted], timeout: 2)
        let safari = try XCTUnwrap(driver.capturedViewController)

        result.cancel()
        do {
            _ = try await result.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertNil(safari.delegate)
        XCTAssertFalse(driver.isPresented)
    }

    func testPersistentPresentationSurvivesBackgroundAndForeground() async throws {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        let returns = ReturnURLs(
            success: URL(string: "mygame://checkout/return")!,
            cancel: URL(string: "mygame://checkout/cancel")!
        )
        let returnedURL = URL(
            string: "mygame://checkout/return?request_id=req_background_presenter"
        )!
        ProcessCoordinator.shared.bindReturn(
            requestID: "req_background_presenter",
            returnURLs: returns
        )
        let presentation = await startPersistentPresentation(callbackURL: returns.success)
        defer { presentation.window.isHidden = true }

        ProcessCoordinator.shared.didEnterBackground()
        ProcessCoordinator.shared.didBecomeActive()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(presentation.driver.isPresented)
        XCTAssertTrue(M2CCheckoutClient.handleOpenURL(returnedURL, returnURLs: returns))
        switch try await presentation.result.value {
        case .returned(let url):
            XCTAssertEqual(url, returnedURL)
        case .dismissed, .ambiguous:
            XCTFail("backgrounding must not settle an in-process Safari checkout")
        }
        XCTAssertFalse(presentation.driver.isPresented)
    }

    private func startPersistentPresentation(
        callbackURL: URL
    ) async -> (
        presenter: SystemBrowserPresenter,
        driver: TestSafariPresentationDriver,
        window: UIWindow,
        result: Task<BrowserOutcome, Error>
    ) {
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let exposed = expectation(description: "Safari checkout exposed")
        var didExpose = false
        let driver = TestSafariPresentationDriver()
        let presenter = SystemBrowserPresenter(safariPresentationDriver: driver)
        let result = Task { @MainActor in
            try await presenter.open(
                checkoutURL: URL(string: "https://vendor.example/pay")!,
                callbackURL: callbackURL,
                mode: .inAppPersistent,
                presentationContext: AttachedPresentationProvider(host: host),
                onExposed: {
                    didExpose = true
                    exposed.fulfill()
                }
            )
        }
        await fulfillment(of: [exposed], timeout: 2)
        if !didExpose {
            result.cancel()
            _ = try? await result.value
        }
        XCTAssertNotNil(driver.capturedViewController)
        XCTAssertTrue(driver.isPresented)
        return (presenter, driver, window, result)
    }
}

@MainActor
private final class DetachedPresentationProvider: NSObject,
    M2CCheckoutPresentationContextProviding {
    var checkoutPresentingViewController: UIViewController? { nil }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

@MainActor
private final class AttachedPresentationProvider: NSObject,
    M2CCheckoutPresentationContextProviding {
    let checkoutPresentingViewController: UIViewController?

    init(host: UIViewController) {
        checkoutPresentingViewController = host
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

@MainActor
private final class TestSafariPresentationDriver: SafariPresentationDriving {
    private(set) var capturedViewController: SFSafariViewController?
    private(set) var isPresented = false
    var onPresentationAttempted: (() -> Void)?
    private let completesPresentation: Bool

    init(completesPresentation: Bool = true) {
        self.completesPresentation = completesPresentation
    }

    func present(
        _ controller: SFSafariViewController,
        from host: UIViewController,
        completion: @escaping () -> Void
    ) {
        capturedViewController = controller
        isPresented = true
        onPresentationAttempted?()
        if completesPresentation {
            completion()
        }
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

    func recordUserDismissal() {
        isPresented = false
    }
}
