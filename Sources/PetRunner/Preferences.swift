import CoreGraphics
import Foundation

struct PetRunnerPreferences {
    private enum Key {
        static let selectedPetID = "selectedPetID"
        static let petWidth = "petWidth"
        static let originX = "originX"
        static let originY = "originY"
        static let hasOrigin = "hasOrigin"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedPetID: String? {
        get { defaults.string(forKey: Key.selectedPetID) }
        nonmutating set { defaults.set(newValue, forKey: Key.selectedPetID) }
    }

    var petWidth: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.petWidth)
            return stored == 0 ? 112 : min(max(stored, 80), 224)
        }
        nonmutating set { defaults.set(min(max(newValue, 80), 224), forKey: Key.petWidth) }
    }

    var origin: CGPoint? {
        get {
            guard defaults.bool(forKey: Key.hasOrigin) else { return nil }
            return CGPoint(
                x: defaults.double(forKey: Key.originX),
                y: defaults.double(forKey: Key.originY)
            )
        }
        nonmutating set {
            guard let newValue else {
                defaults.set(false, forKey: Key.hasOrigin)
                return
            }
            defaults.set(newValue.x, forKey: Key.originX)
            defaults.set(newValue.y, forKey: Key.originY)
            defaults.set(true, forKey: Key.hasOrigin)
        }
    }
}
