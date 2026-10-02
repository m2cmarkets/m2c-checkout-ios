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
        if url.scheme?.lowercased() == "http",
           let host = rawAuthorityHost(url.absoluteString),
           isLoopbackHost(host) { return }
        throw M2CCheckoutError(.invalidRequest, "checkout URL must use HTTPS")
    }

    // URL.host is percent-decoded, and Foundation's parser differs across OS
    // releases, so the plain-HTTP loopback exception reads the host from the
    // URL text. Only an explicit loopback spelling then qualifies, matching the
    // other SDKs' validators.
    private static func rawAuthorityHost(_ value: String) -> String? {
        guard let schemeEnd = value.range(of: "://") else { return nil }
        let rest = value[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            // A second separator makes host selection parser-dependent. Check
            // the %40 form too, because newer Foundation percent-encodes
            // invalid characters when it parses the string.
            let userinfo = authority[..<at]
            if userinfo.firstIndex(of: "@") != nil
                || userinfo.range(of: "%40", options: .caseInsensitive) != nil {
                return nil
            }
            authority = authority[authority.index(after: at)...]
        }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let suffix = authority[authority.index(after: close)...]
            guard suffix.isEmpty || suffix.hasPrefix(":") else { return nil }
            return String(authority[authority.index(after: authority.startIndex)..<close])
        }
        let host = authority.lastIndex(of: ":").map { authority[..<$0] } ?? authority
        return host.isEmpty ? nil : String(host)
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
        if let reference = request.reference {
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !isOpaqueReference(trimmed) {
                throw M2CCheckoutError(
                    .invalidRequest,
                    "reference must be 1-128 characters of letters, digits, '.', '_', ':' or '-'"
                )
            }
        }
        if let referrer = request.referrer, referrer.utf8.count > 2_048 {
            throw M2CCheckoutError(.invalidRequest, "referrer is too long")
        }
        if let segments = request.segments,
           segments.count > 20 || segments.contains(where: { $0.utf8.count > 128 }) {
            throw M2CCheckoutError(.invalidRequest, "segments are invalid")
        }
    }

    public static func validateShopSessionRequest(_ request: ShopSessionRequest) throws {
        guard !request.currency.isEmpty else {
            throw M2CCheckoutError(.invalidRequest, "currency must be non-empty")
        }
        if let language = request.language, language.utf8.count > 64 {
            throw M2CCheckoutError(.invalidRequest, "language is too long")
        }
        if let segments = request.segments,
           segments.count > 20 || segments.contains(where: { $0.utf8.count > 128 }) {
            throw M2CCheckoutError(.invalidRequest, "segments are invalid")
        }
        if let returnURL = request.returnURL { try validateReturnURL(returnURL) }
    }

    // Mirrors the server's model.ValidReference: an opaque order or session ID,
    // never an email, name, or URL.
    static func isOpaqueReference(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x3A || byte == 0x2D
        }
    }
}
