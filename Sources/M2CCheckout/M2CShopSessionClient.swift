import Foundation
import M2CCheckoutCore
import UIKit

public struct ShopSessionHandle: Sendable, Equatable {
    public let sessionID: String
    public let sessionExpiresAt: Date
    public let shopURLExpiresAt: Date
    public let shopURL: URL

    init(
        sessionID: String,
        sessionExpiresAt: Date,
        shopURLExpiresAt: Date,
        shopURL: URL
    ) {
        self.sessionID = sessionID
        self.sessionExpiresAt = sessionExpiresAt
        self.shopURLExpiresAt = shopURLExpiresAt
        self.shopURL = shopURL
    }
}

protocol ShopSessionClock: Sendable {
    func now() -> TimeInterval
}

private struct SystemShopSessionClock: ShopSessionClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
public final class M2CShopSessionClient {
    private let config: M2CSessionConfig
    private let transport: any CheckoutTransporting
    private let browser: any ShopSessionBrowserPresenting
    private let clock: any ShopSessionClock

    public init(config: M2CSessionConfig) throws {
        try CheckoutValidation.validatePublishableKey(config.publishableKey)
        self.config = config
        self.transport = CheckoutTransport()
        self.browser = SystemShopSessionBrowserPresenter()
        self.clock = SystemShopSessionClock()
    }

    public convenience init(config: M2CCheckoutConfig) throws {
        guard let key = config.publishableKey else {
            throw M2CCheckoutError(
                .invalidRequest,
                "publishableKey is required for shop sessions"
            )
        }
        try self.init(
            config: M2CSessionConfig(
                publishableKey: key,
                browserMode: config.browserMode
            )
        )
    }

    init(
        config: M2CSessionConfig,
        transport: any CheckoutTransporting,
        browser: any ShopSessionBrowserPresenting,
        clock: any ShopSessionClock
    ) throws {
        try CheckoutValidation.validatePublishableKey(config.publishableKey)
        self.config = config
        self.transport = transport
        self.browser = browser
        self.clock = clock
    }

    public func startShopSession(
        _ request: ShopSessionRequest,
        from presenter: UIViewController? = nil
    ) async throws -> ShopSessionHandle {
        try CheckoutValidation.validateShopSessionRequest(request)
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        try browser.prepareLaunch(
            mode: config.browserMode,
            presenter: presenter
        )
        let started = clock.now()
        let created = try await transport.createSession(
            request: request,
            publishableKey: config.publishableKey
        )
        try Task.checkCancellation()
        guard clock.now() - started < created.ttl else {
            throw M2CCheckoutError(.checkoutExpired, "shop URL expired before launch")
        }
        try await browser.launch(
            shopURL: created.shopURL,
            returnURL: request.returnURL,
            mode: config.browserMode,
            presenter: presenter
        )
        return ShopSessionHandle(
            sessionID: created.sessionID,
            sessionExpiresAt: created.sessionExpiresAt,
            shopURLExpiresAt: created.shopURLExpiresAt,
            shopURL: created.shopURL
        )
    }

    public func readShopSessionStatus(sessionID: String) async throws -> ShopSessionStatus {
        let canonical = try ShopSessionStatus.canonicalSessionID(sessionID)
        return try await transport.readSessionStatus(
            sessionID: canonical,
            publishableKey: config.publishableKey
        )
    }

    @discardableResult
    public static func handleOpenURL(_ url: URL) -> Bool {
        SystemShopSessionBrowserPresenter.handleOpenURL(url)
    }

    @discardableResult
    public static func handleUserActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL else { return false }
        return handleOpenURL(url)
    }
}
