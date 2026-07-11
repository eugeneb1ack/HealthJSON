import Foundation
import HealthKit

final class AnchorStore {
    private let defaults: UserDefaults
    private let prefix = "health-json.anchor."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func anchor(for typeIdentifier: String) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: prefix + typeIdentifier) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor, for typeIdentifier: String) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        defaults.set(data, forKey: prefix + typeIdentifier)
    }

    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
