import Foundation
import XCTest
@testable import M2CCheckoutCore

final class ConformanceTests: XCTestCase {
    private struct Fixture: Decodable {
        struct CheckoutHelpers: Decodable {
            struct ReturnVector: Decodable {
                let name: String
                let returnURL: String
                let successURL: String
                let cancelURL: String
                let expectedRequestID: String
                let verdict: String
                let requestID: String?
                let error: String?

                enum CodingKeys: String, CodingKey {
                    case name, verdict, error
                    case returnURL = "return_url"
                    case successURL = "success_url"
                    case cancelURL = "cancel_url"
                    case expectedRequestID = "expected_request_id"
                    case requestID = "request_id"
                }
            }

            struct ErrorVector: Decodable {
                let name: String
                let status: Int
                let body: String
                let code: String
            }

            struct ReturnURLPairVector: Decodable {
                let name: String
                let successURL: String
                let cancelURL: String
                let valid: Bool

                enum CodingKeys: String, CodingKey {
                    case name, valid
                    case successURL = "success_url"
                    case cancelURL = "cancel_url"
                }
            }

            let returnClassification: [ReturnVector]
            let returnURLPairs: [ReturnURLPairVector]
            let httpErrorMapping: [ErrorVector]

            enum CodingKeys: String, CodingKey {
                case returnClassification = "return_classification"
                case returnURLPairs = "return_url_pairs"
                case httpErrorMapping = "http_error_mapping"
            }
        }

        struct StatusCoercion: Decodable {
            struct Mapping: Decodable {
                let server: String
                let client: String
            }
            let mappings: [Mapping]
            let unrecognizedFallback: String

            enum CodingKeys: String, CodingKey {
                case mappings
                case unrecognizedFallback = "unrecognized_fallback"
            }
        }

        struct HTTPHelpers: Decodable {
            struct RetryAfterVector: Decodable {
                let name: String
                let header: String?
                let nowMilliseconds: Int64
                let seconds: Int64?

                enum CodingKeys: String, CodingKey {
                    case name, header, seconds
                    case nowMilliseconds = "now_ms"
                }
            }

            struct LoopbackHostVector: Decodable {
                let host: String
                let loopback: Bool
            }

            struct LoopbackURLVector: Decodable {
                let name: String
                let url: String
                let allowed: Bool
            }

            let retryAfter: [RetryAfterVector]
            let loopbackHosts: [LoopbackHostVector]
            let loopbackURLs: [LoopbackURLVector]

            enum CodingKeys: String, CodingKey {
                case retryAfter = "retry_after"
                case loopbackHosts = "loopback_hosts"
                case loopbackURLs = "loopback_urls"
            }
        }

        struct SessionStatusVector: Decodable {
            struct Expected: Decodable {
                let sessionID: String
                let status: String
                let completedPurchases: Int

                enum CodingKeys: String, CodingKey {
                    case sessionID = "session_id"
                    case status
                    case completedPurchases = "completed_purchases"
                }
            }

            let name: String
            let requestedSessionID: String
            let responseJSON: String
            let expected: Expected?
            let error: Bool

            enum CodingKeys: String, CodingKey {
                case name, expected, error
                case requestedSessionID = "requested_session_id"
                case responseJSON = "response_json"
            }
        }

        let checkoutHelpers: CheckoutHelpers
        let httpHelpers: HTTPHelpers
        let statusCoercion: StatusCoercion
        let sessionStatus: [SessionStatusVector]

        enum CodingKeys: String, CodingKey {
            case checkoutHelpers = "checkout_helpers"
            case httpHelpers = "http_helpers"
            case statusCoercion = "status_coercion"
            case sessionStatus = "session_status"
        }
    }

    func testReturnURLPairVectors() throws {
        for vector in try fixture().checkoutHelpers.returnURLPairs {
            let success = try XCTUnwrap(absoluteURL(vector.successURL), vector.name)
            let cancel = try XCTUnwrap(absoluteURL(vector.cancelURL), vector.name)
            let valid: Bool
            do {
                try CheckoutValidation.validateReturnURLs(success: success, cancel: cancel)
                valid = true
            } catch {
                valid = false
            }
            XCTAssertEqual(valid, vector.valid, vector.name)
        }
    }

    func testReturnClassificationVectors() throws {
        for vector in try fixture().checkoutHelpers.returnClassification {
            let success = try XCTUnwrap(absoluteURL(vector.successURL), vector.name)
            let cancel = try XCTUnwrap(absoluteURL(vector.cancelURL), vector.name)
            let result = ReturnClassifier.classify(
                returnURLString: vector.returnURL,
                successURL: success,
                cancelURL: cancel,
                expectedRequestID: vector.expectedRequestID
            )
            XCTAssertEqual(result.verdict.rawValue, vector.verdict, vector.name)
            XCTAssertEqual(result.requestID, vector.requestID, vector.name)
            XCTAssertEqual(result.error, vector.error, vector.name)
        }
    }

    func testHTTPErrorVectors() throws {
        for vector in try fixture().checkoutHelpers.httpErrorMapping {
            let result = HTTPErrorMapper.map(
                status: vector.status,
                body: Data(vector.body.utf8)
            )
            let expected = vector.code.prefix(1).lowercased() + String(vector.code.dropFirst())
            XCTAssertEqual(result.code.rawValue, expected, vector.name)
        }
    }

    func testRetryAfterVectors() throws {
        for vector in try fixture().httpHelpers.retryAfter {
            let result = RetryAfterParser.parse(
                vector.header,
                now: Date(timeIntervalSince1970: TimeInterval(vector.nowMilliseconds) / 1_000)
            )
            XCTAssertEqual(result, vector.seconds.map { TimeInterval($0) }, vector.name)
        }
    }

    func testLoopbackHostVectors() throws {
        for vector in try fixture().httpHelpers.loopbackHosts {
            XCTAssertEqual(CheckoutValidation.isLoopbackHost(vector.host), vector.loopback, vector.host)
            let host = vector.host.contains(":") && !vector.host.hasPrefix("[")
                ? "[" + vector.host + "]"
                : vector.host
            XCTAssertEqual(checkoutURLAllowed("http://" + host + "/checkout"), vector.loopback, vector.host)
        }
    }

    func testLoopbackURLVectors() throws {
        for vector in try fixture().httpHelpers.loopbackURLs {
            XCTAssertEqual(checkoutURLAllowed(vector.url), vector.allowed, vector.name)
        }
    }

    func testStatusCoercionVectors() throws {
        let vectors = try fixture().statusCoercion
        for mapping in vectors.mappings {
            XCTAssertEqual(StatusCoercion.coerce(mapping.server).rawValue, mapping.client)
        }
        XCTAssertEqual(StatusCoercion.coerce("future-status").rawValue, vectors.unrecognizedFallback)
    }

    func testShopSessionStatusVectors() throws {
        for vector in try fixture().sessionStatus {
            do {
                let result = try ShopSessionStatus.parse(
                    response: Data(vector.responseJSON.utf8),
                    requestedSessionID: vector.requestedSessionID
                )
                XCTAssertFalse(vector.error, vector.name)
                XCTAssertEqual(result.sessionID, vector.expected?.sessionID, vector.name)
                XCTAssertEqual(result.status.rawValue, vector.expected?.status, vector.name)
                XCTAssertEqual(result.completedPurchases, vector.expected?.completedPurchases, vector.name)
            } catch {
                XCTAssertTrue(vector.error, vector.name)
            }
        }
    }

    // An authority Foundation refuses to parse cannot reach a checkout, so it
    // counts as rejected, matching the other SDKs' validators.
    private func checkoutURLAllowed(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        do {
            try CheckoutValidation.validateCheckoutURL(url)
            return true
        } catch {
            return false
        }
    }

    private func absoluteURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    private func fixture() throws -> Fixture {
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("kat/m2c-protocol-vectors.json")
        let url = Bundle.module.url(
            forResource: "m2c-protocol-vectors",
            withExtension: "json"
        ) ?? sourceFallback
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }
}
