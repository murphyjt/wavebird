import Foundation

// One-time UserDefaults cleanups for superseded features.
enum LegacyMigrations {
    // Per-serial "WaveBird.axis.<serial>" Y-inversion is replaced by per-profile
    // stick transforms. Profiles are shared across controllers while the old
    // keys were per-serial, so there is no faithful migration — drop the orphans.
    static func dropLegacyAxisSettings(_ defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("WaveBird.axis.") {
            defaults.removeObject(forKey: key)
        }
    }
}
