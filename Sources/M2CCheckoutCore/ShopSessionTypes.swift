import Foundation

public struct ShopSessionRequest: Sendable, Equatable {
    public let currency: String
    public let language: String?
    public let segments: [String]?
    public let returnURL: URL?

    public init(
        currency: String,
        language: String? = nil,
        segments: [String]? = nil,
        returnURL: URL? = nil
    ) {
        self.currency = currency
        self.language = language
        self.segments = segments
        self.returnURL = returnURL
    }
}

public enum ShopSessionState: String, Codable, Sendable, Equatable {
    case active
    case expired
}

public struct ShopSessionStatus: Sendable, Equatable {
    public let sessionID: String
    public let status: ShopSessionState
    public let completedPurchases: Int

    public init(sessionID: String, status: ShopSessionState, completedPurchases: Int) {
        self.sessionID = sessionID
        self.status = status
        self.completedPurchases = completedPurchases
    }

    public static func canonicalSessionID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value.lowercased() else {
            throw M2CCheckoutError(.invalidRequest, "sessionID must be a canonical UUID")
        }
        return uuid.uuidString.lowercased()
    }

    public static func parse(response data: Data, requestedSessionID: String) throws -> Self {
        let canonical = try canonicalSessionID(requestedSessionID)
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw M2CCheckoutError(.unknown, "session status response had an unexpected shape")
        }
        guard wire.sessionID == canonical,
              wire.completedPurchases >= 0,
              wire.completedPurchases <= Int(Int32.max) else {
            throw M2CCheckoutError(.unknown, "session status response had an unexpected shape")
        }
        return Self(
            sessionID: canonical,
            status: wire.status,
            completedPurchases: wire.completedPurchases
        )
    }

    private struct Wire: Decodable {
        let sessionID: String
        let status: ShopSessionState
        let completedPurchases: Int

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case status
            case completedPurchases = "completed_purchases"
        }
    }
}
