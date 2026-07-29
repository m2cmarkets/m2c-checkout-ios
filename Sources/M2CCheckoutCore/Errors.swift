import Foundation

public enum M2CCheckoutErrorCode: String, Codable, Sendable {
    case network
    case invalidRequest
    case authenticationFailed
    case originNotAllowed
    case accountSuspended
    case noVendorsAvailable
    case rateLimited
    case serviceUnavailable
    case checkoutExpired
    case unknown
}

public struct M2CCheckoutError: Error, LocalizedError, Sendable, Equatable {
    public let code: M2CCheckoutErrorCode
    public let message: String
    public let httpStatus: Int?
    public let retryAfter: TimeInterval?
    public let fallbackStatus: FallbackStatus?

    public init(
        _ code: M2CCheckoutErrorCode,
        _ message: String,
        httpStatus: Int? = nil,
        retryAfter: TimeInterval? = nil,
        fallbackStatus: FallbackStatus? = nil
    ) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
        self.retryAfter = retryAfter
        self.fallbackStatus = fallbackStatus
    }

    public var errorDescription: String? { message }

    public func withFallbackStatus(_ status: FallbackStatus) -> M2CCheckoutError {
        M2CCheckoutError(
            code,
            message,
            httpStatus: httpStatus,
            retryAfter: retryAfter,
            fallbackStatus: status
        )
    }
}

public enum HTTPErrorMapper {
    public static func map(status: Int, body: Data, retryAfter: TimeInterval? = nil) -> M2CCheckoutError {
        let message = errorMessage(body) ?? "request returned HTTP \(status)"
        let code: M2CCheckoutErrorCode
        switch status {
        case 400:
            code = .invalidRequest
        case 401:
            code = .authenticationFailed
        case 403:
            code = message.range(of: "suspend", options: .caseInsensitive) == nil
                ? .originNotAllowed
                : .accountSuspended
        case 404:
            code = .noVendorsAvailable
        case 429:
            code = .rateLimited
        case 500...599:
            code = .serviceUnavailable
        default:
            code = .unknown
        }
        return M2CCheckoutError(
            code,
            message,
            httpStatus: status,
            retryAfter: retryAfter
        )
    }

    private static func errorMessage(_ body: Data) -> String? {
        guard
            let value = try? JSONSerialization.jsonObject(with: body),
            let object = value as? [String: Any],
            let message = object["error"] as? String
        else { return nil }
        return String(message.prefix(1_024))
    }
}
