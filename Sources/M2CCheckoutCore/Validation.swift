import Foundation

public enum CheckoutValidation {
    private static let reservedReturnSchemes: Set<String> = [
        "http", "file", "data", "javascript", "about", "ftp", "mailto",
        "tel", "sms", "intent", "market"
    ]

    public static func validatePublishableKey(_ key: String?) throws {
        guard let key, key.hasPrefix("pub_") || key.hasPrefix("pub_test_") else {
            throw M2CCheckoutError(
                .invalidRequest,
                "publishableKey must begin with pub_ or pub_test_"
            )
        }
    }

    public static func validateCheckoutURL(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 4_096 else {
            throw M2CCheckoutError(.invalidRequest, "checkout URL is too long")
        }
        guard url.host != nil, url.scheme != nil, url.baseURL == nil else {
            throw M2CCheckoutError(.invalidRequest, "checkout URL must be absolute")
        }
        if url.scheme?.lowercased() == "https" { return }
        if url.scheme?.lowercased() == "http", isLoopbackHost(url.host ?? "") { return }
        throw M2CCheckoutError(.invalidRequest, "checkout URL must use HTTPS")
    }

    public static func validateReturnURL(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 2_048 else {
            throw M2CCheckoutError(.invalidRequest, "return URL is too long")
        }
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty, url.baseURL == nil else {
            throw M2CCheckoutError(.invalidRequest, "return URL must be absolute")
        }
        if scheme == "https" {
            guard url.host != nil else {
                throw M2CCheckoutError(.invalidRequest, "HTTPS return URL must include a host")
            }
            return
        }
        guard !reservedReturnSchemes.contains(scheme) else {
            throw M2CCheckoutError(.invalidRequest, "return URL scheme is not allowed")
        }
    }

    public static func validateReturnURLs(success: URL, cancel: URL) throws {
        try validateReturnURL(success)
        try validateReturnURL(cancel)
        guard !ReturnURLMatcher.matches(success, configured: cancel) else {
            throw M2CCheckoutError(
                .invalidRequest,
                "success and cancel return URLs overlap"
            )
        }
    }

    public static func validateStatusTemplate(_ template: String) throws {
        guard template.contains("{request_id}") else {
            throw M2CCheckoutError(.invalidRequest, "status URL template must contain {request_id}")
        }
        let probe = template.replacingOccurrences(of: "{request_id}", with: "probe")
        guard let url = URL(string: probe) else {
            throw M2CCheckoutError(.invalidRequest, "status URL template is malformed")
        }
        try validateCheckoutURL(url)
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else {
                return false
            }
            return number >= 0 && number <= 255
        }
    }

    public static func validateRequest(_ request: AuctionRequest) throws {
        let numericValue = NSDecimalNumber(decimal: request.transactionValue).doubleValue
        guard numericValue.isFinite,
              numericValue >= 0.000001,
              numericValue <= 5_000_000_000 else {
            throw M2CCheckoutError(.invalidRequest, "transactionValue is outside the supported range")
        }
        if let currency = request.currency, currency.isEmpty {
            throw M2CCheckoutError(.invalidRequest, "currency must be non-empty")
        }
        if let description = request.description, description.utf8.count > 256 {
            throw M2CCheckoutError(.invalidRequest, "description is too long")
        }
        if let reference = request.reference, reference.utf8.count > 512 {
            throw M2CCheckoutError(.invalidRequest, "reference is too long")
        }
        if let referrer = request.referrer, referrer.utf8.count > 2_048 {
            throw M2CCheckoutError(.invalidRequest, "referrer is too long")
        }
        if let segments = request.segments,
           segments.count > 20 || segments.contains(where: { $0.utf8.count > 128 }) {
            throw M2CCheckoutError(.invalidRequest, "segments are invalid")
        }
    }
}
