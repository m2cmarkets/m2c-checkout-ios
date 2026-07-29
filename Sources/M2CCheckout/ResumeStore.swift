import Foundation
import M2CCheckoutCore

@MainActor
protocol ResumeStoring: AnyObject {
    func load() -> ResumeRecord?
    func save(_ record: ResumeRecord) throws
    func clear()
}

@MainActor
final class UserDefaultsResumeStore: ResumeStoring {
    private let defaults: UserDefaults
    private let key = "com.m2c.checkout.resume.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ResumeRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let record = ResumeRecord.decode(data) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return record
    }

    func save(_ record: ResumeRecord) throws {
        defaults.set(try record.encode(), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
