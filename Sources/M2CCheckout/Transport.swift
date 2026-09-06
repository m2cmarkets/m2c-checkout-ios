import Foundation
import M2CCheckoutCore

private let productionBaseURL = URL(string: "https://api.m2cmarkets.com")!
let maximumResponseBodyBytes = 64 * 1_024

protocol CheckoutTransporting: AnyObject, Sendable {
    func createAuction(
        request: AuctionRequest,
        returnURLs: ReturnURLs,
        publishableKey: String,
        timeout: TimeInterval
    ) async throws -> CheckoutSession
    func readM2CStatus(requestID: String, publishableKey: String) async throws -> ClientStatus
    func readURLStatus(template: String, requestID: String) async throws -> ClientStatus
    func createSession(
        request: ShopSessionRequest,
        publishableKey: String
    ) async throws -> CreatedShopSession
    func readSessionStatus(
        sessionID: String,
        publishableKey: String
    ) async throws -> ShopSessionStatus
}

struct CreatedShopSession: Sendable {
    let sessionID: String
    let sessionExpiresAt: Date
    let shopURLExpiresAt: Date
    let shopURL: URL
    let ttl: TimeInterval
}

extension CheckoutTransporting {
    func createSession(
        request: ShopSessionRequest,
        publishableKey: String
    ) async throws -> CreatedShopSession {
        throw M2CCheckoutError(.unknown, "shop session transport is not implemented")
    }

    func readSessionStatus(
        sessionID: String,
        publishableKey: String
    ) async throws -> ShopSessionStatus {
        throw M2CCheckoutError(.unknown, "shop session transport is not implemented")
    }
}

final class CheckoutTransport: CheckoutTransporting, @unchecked Sendable {
    private let session: URLSession
    private let sessionDelegate: BoundedSessionDelegate
    private let baseURL: URL

    init(
        configuration suppliedConfiguration: URLSessionConfiguration? = nil,
        baseURL: URL = productionBaseURL
    ) {
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let delegate = BoundedSessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.baseURL = baseURL
    }

    deinit {
        session.invalidateAndCancel()
    }

    func createAuction(
        request: AuctionRequest,
        returnURLs: ReturnURLs,
        publishableKey: String,
        timeout: TimeInterval
    ) async throws -> CheckoutSession {
        try CheckoutValidation.validateRequest(request)
        let successURL = returnURLs.success
        let cancelURL = returnURLs.cancel
        try CheckoutValidation.validateReturnURLs(success: successURL, cancel: cancelURL)

        let body = AuctionWireRequest(
            transactionValue: request.transactionValue,
            currency: request.currency,
            description: request.description,
            successURL: successURL.absoluteString,
            cancelURL: cancelURL.absoluteString,
            reference: request.reference,
            segments: request.segments,
            language: request.language,
            referrer: request.referrer
        )
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/v1/auction"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.httpShouldHandleCookies = false
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(publishableKey, forHTTPHeaderField: "X-API-Key")

        let (data, response) = try await send(urlRequest)
        guard response.statusCode == 200 else {
            throw HTTPErrorMapper.map(
                status: response.statusCode,
                body: data,
                retryAfter: RetryAfterParser.parse(response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        let wire: AuctionWireResponse
        do {
            wire = try JSONDecoder().decode(AuctionWireResponse.self, from: data)
        } catch {
            throw M2CCheckoutError(.unknown, "auction response had an unexpected shape")
        }
        guard !wire.requestID.isEmpty, wire.winner.ttl > 0,
              let checkoutURL = URL(string: wire.winner.checkoutURL) else {
            throw M2CCheckoutError(.unknown, "auction response was missing required fields")
        }
        try CheckoutValidation.validateCheckoutURL(checkoutURL)
        return CheckoutSession(
            checkoutURL: checkoutURL,
            requestID: wire.requestID,
            ttl: TimeInterval(wire.winner.ttl)
        )
    }

    func readM2CStatus(requestID: String, publishableKey: String) async throws -> ClientStatus {
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("api/v1/conversions")
                .appendingPathComponent(requestID)
        )
        request.setValue(publishableKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await send(request)
        if response.statusCode == 404 { return .processing }
        guard response.statusCode == 200 else {
            throw HTTPErrorMapper.map(
                status: response.statusCode,
                body: data,
                retryAfter: RetryAfterParser.parse(response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        guard let wire = try? JSONDecoder().decode(StatusWireResponse.self, from: data),
              wire.requestID == requestID else {
            throw M2CCheckoutError(.unknown, "status response had an unexpected shape")
        }
        return StatusCoercion.coerce(wire.status)
    }

    func readURLStatus(template: String, requestID: String) async throws -> ClientStatus {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "/?&=#"))
        let escaped = requestID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard let url = URL(string: template.replacingOccurrences(of: "{request_id}", with: escaped))
        else {
            throw M2CCheckoutError(.invalidRequest, "status URL template is malformed")
        }
        let (data, response) = try await send(URLRequest(url: url))
        guard (200...299).contains(response.statusCode) else {
            throw M2CCheckoutError(
                .serviceUnavailable,
                "merchant status endpoint returned HTTP \(response.statusCode)",
                httpStatus: response.statusCode,
                retryAfter: RetryAfterParser.parse(
                    response.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
        let status = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }?["status"] as? String
        return StatusCoercion.coerce(status ?? "")
    }

    func createSession(
        request: ShopSessionRequest,
        publishableKey: String
    ) async throws -> CreatedShopSession {
        try CheckoutValidation.validateShopSessionRequest(request)
        let body = ShopSessionWireRequest(
            currency: request.currency,
            language: request.language,
            segments: request.segments,
            returnURL: request.returnURL?.absoluteString
        )
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/v1/session"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.httpShouldHandleCookies = false
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(publishableKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await send(urlRequest)
        guard response.statusCode == 200 else {
            let retryAfter = RetryAfterParser.parse(response.value(forHTTPHeaderField: "Retry-After"))
            if response.statusCode == 409 {
                let mapped = HTTPErrorMapper.map(status: 400, body: data)
                throw M2CCheckoutError(
                    .invalidRequest,
                    mapped.message,
                    httpStatus: 409
                )
            }
            throw HTTPErrorMapper.map(
                status: response.statusCode,
                body: data,
                retryAfter: retryAfter
            )
        }
        let wire: ShopSessionWireResponse
        do {
            wire = try JSONDecoder().decode(ShopSessionWireResponse.self, from: data)
        } catch {
            throw M2CCheckoutError(.unknown, "session response had an unexpected shape")
        }
        let sessionID: String
        do {
            sessionID = try ShopSessionStatus.canonicalSessionID(wire.sessionID)
        } catch {
            throw M2CCheckoutError(.unknown, "session response had an unexpected shape")
        }
        guard wire.winner.ttl >= 60, wire.winner.ttl <= 3_600,
              let sessionExpiresAt = Self.parseRFC3339(wire.expiresAt),
              let shopURLExpiresAt = Self.parseRFC3339(wire.winner.launchExpiresAt),
              let shopURL = URL(string: wire.winner.shopURL) else {
            throw M2CCheckoutError(.unknown, "session response had an unexpected shape")
        }
        do {
            try CheckoutValidation.validateCheckoutURL(shopURL)
        } catch {
            throw M2CCheckoutError(.unknown, "session response had an unexpected shape")
        }
        return CreatedShopSession(
            sessionID: sessionID,
            sessionExpiresAt: sessionExpiresAt,
            shopURLExpiresAt: shopURLExpiresAt,
            shopURL: shopURL,
            ttl: TimeInterval(wire.winner.ttl)
        )
    }

    func readSessionStatus(
        sessionID: String,
        publishableKey: String
    ) async throws -> ShopSessionStatus {
        let canonical = try ShopSessionStatus.canonicalSessionID(sessionID)
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/session-status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "session_id", value: canonical)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue(publishableKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await send(request)
        if response.statusCode == 404 {
            throw M2CCheckoutError(
                .sessionNotFound,
                "shop session was not found",
                httpStatus: 404
            )
        }
        guard response.statusCode == 200 else {
            throw HTTPErrorMapper.map(
                status: response.statusCode,
                body: data,
                retryAfter: RetryAfterParser.parse(
                    response.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
        return try ShopSessionStatus.parse(response: data, requestedSessionID: canonical)
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        guard let decimal = value.firstIndex(of: ".") else {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        let fractionStart = value.index(after: decimal)
        guard let zoneStart = value[fractionStart...].firstIndex(where: {
            $0 == "Z" || $0 == "+" || $0 == "-"
        }) else {
            return nil
        }
        let fraction = value[fractionStart..<zoneStart]
        guard (1...9).contains(fraction.count),
              fraction.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        let milliseconds = String(fraction.prefix(3))
            + String(repeating: "0", count: max(0, 3 - fraction.count))
        let normalized = String(value[..<fractionStart])
            + milliseconds
            + String(value[zoneStart...])
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: normalized)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let state = URLSessionRequestState()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                sessionDelegate.register(task: task, state: state)
                state.install(task: task, continuation: continuation)
            }
            try Task.checkCancellation()
            return result
        }, onCancel: {
            state.cancel()
        })
    }

}

private final class URLSessionRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var result: Result<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var data = Data()

    func install(
        task: URLSessionDataTask,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            task.cancel()
            continuation.resume(with: result)
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func cancel() {
        resolve(.failure(CancellationError()), cancelTask: true)
    }

    func receive(response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else {
            resolve(
                .failure(M2CCheckoutError(.network, "request returned no HTTP response")),
                cancelTask: true
            )
            return false
        }
        if response.expectedContentLength > Int64(maximumResponseBodyBytes) {
            resolve(.failure(Self.oversizedResponseError), cancelTask: true)
            return false
        }

        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        self.response = response
        lock.unlock()
        return true
    }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        guard chunk.count <= maximumResponseBodyBytes - data.count else {
            lock.unlock()
            resolve(.failure(Self.oversizedResponseError), cancelTask: true)
            return false
        }
        data.append(chunk)
        lock.unlock()
        return true
    }

    func complete(error: Error?) {
        let completion: Result<(Data, HTTPURLResponse), Error>
        if (error as? URLError)?.code == .cancelled {
            completion = .failure(CancellationError())
        } else if let error {
            completion = .failure(
                M2CCheckoutError(.network, "request failed: \(error.localizedDescription)")
            )
        } else {
            lock.lock()
            let response = self.response
            let data = self.data
            lock.unlock()
            if let response {
                completion = .success((data, response))
            } else {
                completion = .failure(
                    M2CCheckoutError(.network, "request returned no HTTP response")
                )
            }
        }
        resolve(completion, cancelTask: false)
    }

    private func resolve(
        _ newResult: Result<(Data, HTTPURLResponse), Error>,
        cancelTask: Bool
    ) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()

        if cancelTask { task?.cancel() }
        continuation?.resume(with: newResult)
    }

    private static let oversizedResponseError = M2CCheckoutError(
        .unknown,
        "response body exceeded \(maximumResponseBodyBytes) bytes"
    )
}

private final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int: URLSessionRequestState] = [:]

    func register(task: URLSessionDataTask, state: URLSessionRequestState) {
        lock.lock()
        states[task.taskIdentifier] = state
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(state(for: dataTask)?.receive(response: response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = state(for: dataTask)?.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        state?.complete(error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func state(for task: URLSessionTask) -> URLSessionRequestState? {
        lock.lock()
        let state = states[task.taskIdentifier]
        lock.unlock()
        return state
    }
}

private struct AuctionWireRequest: Encodable {
    let transactionValue: Decimal
    let currency: String?
    let description: String?
    let successURL: String
    let cancelURL: String
    let reference: String?
    let segments: [String]?
    let language: String?
    let referrer: String?
    let deviceType = "mobile"
    let platform = "ios"

    enum CodingKeys: String, CodingKey {
        case transactionValue = "transaction_value"
        case currency, description
        case successURL = "success_url"
        case cancelURL = "cancel_url"
        case reference, segments, language, referrer
        case deviceType = "device_type"
        case platform
    }
}

private struct AuctionWireResponse: Decodable {
    struct Winner: Decodable {
        let checkoutURL: String
        let ttl: Double

        enum CodingKeys: String, CodingKey {
            case checkoutURL = "checkout_url"
            case ttl
        }
    }

    let winner: Winner
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case winner
        case requestID = "request_id"
    }
}

private struct StatusWireResponse: Decodable {
    let requestID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status
    }
}

private struct ShopSessionWireRequest: Encodable {
    let currency: String
    let language: String?
    let segments: [String]?
    let returnURL: String?
    let deviceType = "mobile"
    let platform = "ios"

    enum CodingKeys: String, CodingKey {
        case currency, language, segments, platform
        case returnURL = "return_url"
        case deviceType = "device_type"
    }
}

private struct ShopSessionWireResponse: Decodable {
    struct Winner: Decodable {
        let shopURL: String
        let ttl: Int
        let launchExpiresAt: String

        enum CodingKeys: String, CodingKey {
            case shopURL = "shop_url"
            case ttl
            case launchExpiresAt = "launch_expires_at"
        }
    }

    let winner: Winner
    let sessionID: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case winner
        case sessionID = "session_id"
        case expiresAt = "expires_at"
    }
}
