import Foundation

public struct ResumeRecord: Codable, Sendable, Equatable {
    public enum IntegrationMode: String, Codable, Sendable {
        case backend
        case client
    }

    public enum SourceKind: String, Codable, Sendable {
        case m2c
        case url
        case callback
    }

    public let version: Int
    public let requestID: String
    public let integrationMode: IntegrationMode
    public let sourceKind: SourceKind
    public let statusURLTemplate: String?
    public let successReturnURL: String
    public let cancelReturnURL: String

    public init(
        requestID: String,
        integrationMode: IntegrationMode,
        sourceKind: SourceKind,
        statusURLTemplate: String? = nil,
        successReturnURL: String,
        cancelReturnURL: String
    ) {
        self.version = 1
        self.requestID = requestID
        self.integrationMode = integrationMode
        self.sourceKind = sourceKind
        self.statusURLTemplate = statusURLTemplate
        self.successReturnURL = successReturnURL
        self.cancelReturnURL = cancelReturnURL
    }

    public static func decode(_ data: Data, maximumBytes: Int = 16_384) -> ResumeRecord? {
        guard data.count <= maximumBytes,
              let record = try? JSONDecoder().decode(ResumeRecord.self, from: data),
              record.version == 1,
              !record.requestID.isEmpty,
              !record.successReturnURL.isEmpty,
              !record.cancelReturnURL.isEmpty else {
            return nil
        }
        return record
    }

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
