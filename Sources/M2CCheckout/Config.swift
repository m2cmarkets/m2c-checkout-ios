import AuthenticationServices
import Foundation
import M2CCheckoutCore
import UIKit

public enum BrowserMode: Sendable, Equatable {
    case inAppPreferred
    case inAppPersistent
    case externalBrowser
}

public struct M2CSessionConfig: Sendable {
    public let publishableKey: String
    public let browserMode: BrowserMode

    public init(
        publishableKey: String,
        browserMode: BrowserMode = .inAppPreferred
    ) {
        self.publishableKey = publishableKey
        self.browserMode = browserMode
    }
}

@MainActor
public protocol M2CCheckoutPresentationContextProviding:
    AnyObject, ASWebAuthenticationPresentationContextProviding {
    var checkoutPresentingViewController: UIViewController? { get }
}

public enum StatusSource: @unchecked Sendable {
    case m2c
    case url(template: String)
    case callback(@Sendable (String) async throws -> ClientStatus)
    case subscribe
}

public struct M2CStatusBackstop: Sendable {
    public var enabled: Bool
    public var threshold: TimeInterval

    public init(enabled: Bool = false, threshold: TimeInterval = 10) {
        self.enabled = enabled
        self.threshold = min(60, max(5, threshold))
    }
}

public typealias CheckoutFallbackHandler = @MainActor @Sendable (
    FallbackReason,
    FallbackContext
) async throws -> FallbackDecision

public struct M2CCheckoutConfig: @unchecked Sendable {
    public let publishableKey: String?
    public let returnURLs: ReturnURLs
    public let statusSource: StatusSource
    public let poll: PollPolicy
    public let browserMode: BrowserMode
    public let statusBackstop: M2CStatusBackstop
    public let fallbackDeadline: TimeInterval
    public let fallbackHandler: CheckoutFallbackHandler?

    public init(
        publishableKey: String? = nil,
        returnURLs: ReturnURLs,
        statusSource: StatusSource,
        poll: PollPolicy = .default,
        browserMode: BrowserMode = .inAppPreferred,
        statusBackstop: M2CStatusBackstop = .init(),
        fallbackDeadline: TimeInterval = 10,
        fallbackHandler: CheckoutFallbackHandler? = nil
    ) {
        self.publishableKey = publishableKey
        self.returnURLs = returnURLs
        self.statusSource = statusSource
        self.poll = poll
        self.browserMode = browserMode
        self.statusBackstop = statusBackstop
        self.fallbackDeadline = fallbackDeadline
        self.fallbackHandler = fallbackHandler
    }
}
