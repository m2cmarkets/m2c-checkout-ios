import Foundation

public enum ClientStatus: String, Codable, Sendable {
    case processing
    case completed
    case failed
    case canceled
}

public enum CheckoutState: String, Codable, Sendable {
    case idle
    case creating
    case ready
    case launching
    case awaitingReturn
    case returned
    case polling
    case completed
    case failed
    case canceled
    case pendingTimeout
    case fallbackStarted
    case error
}

public enum FallbackReason: String, Codable, Sendable, Equatable {
    case noBids
    case timeout
    case apiError
    case launchFailed
}

public enum FallbackDecision: Sendable {
    case unavailable
    case accepted
}

public enum FallbackMode: Sendable {
    case inherit
    case disabled
}

public enum FallbackStatus: String, Codable, Sendable {
    case declined
    case handlerOutcomeUnknown
}

public struct CheckoutStartOptions: Sendable {
    public var fallbackMode: FallbackMode
    public var fallbackProductID: String?

    public init(fallbackMode: FallbackMode = .inherit, fallbackProductID: String? = nil) {
        self.fallbackMode = fallbackMode
        self.fallbackProductID = fallbackProductID
    }
}

public struct FallbackContext: Sendable {
    public let attemptID: String
    public let reason: FallbackReason
    public let originalError: M2CCheckoutError
    public let requestID: String?
    public let fallbackProductID: String?
    public let latencyMilliseconds: Int64
    public let transactionValue: Decimal?
    public let currency: String?
    public let description: String?
    public let reference: String?

    public init(
        attemptID: String,
        reason: FallbackReason,
        originalError: M2CCheckoutError,
        requestID: String?,
        fallbackProductID: String?,
        latencyMilliseconds: Int64,
        transactionValue: Decimal?,
        currency: String?,
        description: String?,
        reference: String?
    ) {
        self.attemptID = attemptID
        self.reason = reason
        self.originalError = originalError
        self.requestID = requestID
        self.fallbackProductID = fallbackProductID
        self.latencyMilliseconds = latencyMilliseconds
        self.transactionValue = transactionValue
        self.currency = currency
        self.description = description
        self.reference = reference
    }
}

public enum CheckoutResult: Sendable, Equatable {
    case completed(requestID: String)
    case failed(requestID: String)
    case canceled(requestID: String)
    case pendingTimeout(requestID: String)
    case fallbackStarted(attemptID: String, requestID: String?, reason: FallbackReason)
}

public struct CheckoutSession: Sendable {
    public let checkoutURL: URL
    public let requestID: String
    public let ttl: TimeInterval?

    public init(checkoutURL: URL, requestID: String, ttl: TimeInterval? = nil) {
        self.checkoutURL = checkoutURL
        self.requestID = requestID
        self.ttl = ttl
    }
}

public struct AuctionRequest: Sendable {
    public let transactionValue: Decimal
    public let currency: String?
    public let description: String?
    public let successURL: URL?
    public let cancelURL: URL?
    public let reference: String?
    public let segments: [String]?
    public let language: String?
    public let referrer: String?

    public init(
        transactionValue: Decimal,
        currency: String? = nil,
        description: String? = nil,
        successURL: URL? = nil,
        cancelURL: URL? = nil,
        reference: String? = nil,
        segments: [String]? = nil,
        language: String? = nil,
        referrer: String? = nil
    ) {
        self.transactionValue = transactionValue
        self.currency = currency
        self.description = description
        self.successURL = successURL
        self.cancelURL = cancelURL
        self.reference = reference
        self.segments = segments
        self.language = language
        self.referrer = referrer
    }
}

public struct ReturnURLs: Sendable {
    public let success: URL
    public let cancel: URL

    public init(success: URL, cancel: URL) {
        self.success = success
        self.cancel = cancel
    }
}

public struct PollPolicy: Sendable {
    private static let maximumTimerInterval: TimeInterval = 2_147_483.647

    public var timeout: TimeInterval
    public var delays: [TimeInterval]

    public init(
        timeout: TimeInterval = 90,
        delays: [TimeInterval] = [0, 1, 2, 4, 8]
    ) {
        self.timeout = timeout
        self.delays = delays
    }

    public static let `default` = PollPolicy()

    public func validate() throws {
        guard timeout.isFinite,
              timeout > 0,
              timeout <= Self.maximumTimerInterval else {
            throw M2CCheckoutError(
                .invalidRequest,
                "poll timeout must be positive, finite, and within the platform timer limit"
            )
        }
        guard delays.allSatisfy({
            $0.isFinite && $0 >= 0 && $0 <= Self.maximumTimerInterval
        }) else {
            throw M2CCheckoutError(
                .invalidRequest,
                "poll delays must be nonnegative, finite, and within the platform timer limit"
            )
        }
    }
}
