import Foundation

public enum ReturnVerdict: String, Sendable, Equatable {
    case success
    case cancel
    case unknown
}

public struct ReturnClassification: Sendable, Equatable {
    public let verdict: ReturnVerdict
    public let requestID: String?
    public let error: String?

    public init(verdict: ReturnVerdict, requestID: String?, error: String? = nil) {
        self.verdict = verdict
        self.requestID = requestID
        self.error = error
    }
}

public enum ReturnClassifier {
    static func classify(
        returnURLString: String,
        successURL: URL,
        cancelURL: URL,
        expectedRequestID: String
    ) -> ReturnClassification {
        guard
            let returnURL = URL(string: returnURLString),
            let scheme = returnURL.scheme,
            !scheme.isEmpty
        else {
            return ReturnClassification(
                verdict: .unknown,
                requestID: nil,
                error: "malformed_url"
            )
        }
        return classify(
            returnURL: returnURL,
            successURL: successURL,
            cancelURL: cancelURL,
            expectedRequestID: expectedRequestID
        )
    }

    public static func classify(
        returnURL: URL,
        successURL: URL,
        cancelURL: URL,
        expectedRequestID: String
    ) -> ReturnClassification {
        let requestID = URLComponents(url: returnURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "request_id" })?
            .value

        let verdict: ReturnVerdict
        if ReturnURLMatcher.matches(returnURL, configured: cancelURL) {
            verdict = .cancel
        } else if ReturnURLMatcher.matches(returnURL, configured: successURL) {
            verdict = .success
        } else {
            return ReturnClassification(verdict: .unknown, requestID: requestID)
        }

        if let requestID, requestID != expectedRequestID {
            return ReturnClassification(
                verdict: .unknown,
                requestID: requestID,
                error: "request_id_mismatch"
            )
        }
        return ReturnClassification(verdict: verdict, requestID: requestID ?? expectedRequestID)
    }
}

package enum ReturnURLMatcher {
    package static func matches(_ actual: URL, configured: URL) -> Bool {
        guard
            let a = normalized(actual),
            let b = normalized(configured),
            a.scheme.caseInsensitiveCompare(b.scheme) == .orderedSame,
            a.host.caseInsensitiveCompare(b.host) == .orderedSame,
            a.port == b.port
        else {
            return false
        }
        if a.path == b.path { return true }
        let prefix = b.path == "/" ? "/" : b.path + "/"
        return a.path.hasPrefix(prefix)
    }

    private static func normalized(_ url: URL) -> (
        scheme: String,
        host: String,
        port: Int?,
        path: String
    )? {
        guard let scheme = url.scheme else { return nil }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return (scheme, url.host ?? "", url.port, path.isEmpty ? "/" : path)
    }
}
