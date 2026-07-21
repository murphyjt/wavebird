import Foundation
import Observation

// Owns the user's custom mapping profiles and synthesizes the built-in
// defaults from the output catalog. Persists one JSON blob per profile under
// a single UserDefaults dictionary key so one corrupt record is dropped
// without losing the rest (decode-with-recovery per the design spec).
@MainActor
@Observable
final class MappingProfileStore {
    static let defaultsKey = "WaveBird.mappingProfiles"

    private let catalog: HIDOutputCatalog
    private let defaults: UserDefaults
    private(set) var customProfiles: [MappingProfile] = []

    init(catalog: HIDOutputCatalog = .default, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        load()
    }

    // One read-only default per catalog entry (DEBUG-only modes included in
    // DEBUG builds automatically — the catalog only contains them there).
    var builtInProfiles: [MappingProfile] {
        catalog.entries.compactMap { builtInProfile(forModeID: $0.id) }
    }

    // Accepts well-known default IDs, custom IDs, and bare legacy output-mode
    // IDs (pre-profiles preferredOutputModeID values resolve to that mode's
    // default profile — migration by interpretation, never rewriting).
    func profile(id: String) -> MappingProfile? {
        if let custom = customProfiles.first(where: { $0.id == id }) { return custom }
        if id.hasPrefix(MappingProfile.defaultIDPrefix) {
            let modeID = String(id.dropFirst(MappingProfile.defaultIDPrefix.count))
            return builtInProfile(forModeID: modeID)
        }
        return builtInProfile(forModeID: id)
    }

    func upsert(_ profile: MappingProfile) {
        guard !profile.isBuiltIn else { return }
        customProfiles.removeAll { $0.id == profile.id }
        customProfiles.append(profile)
        customProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    // Creates an editable custom copy of any profile (built-in or custom): a
    // fresh UUID so it's a custom, a Finder-style deduped " copy" name, and
    // everything else carried over.
    @discardableResult
    func duplicate(_ source: MappingProfile) -> MappingProfile {
        var copy = source
        copy.id = UUID().uuidString
        copy.name = uniqueCopyName(basedOn: source.name)
        upsert(copy)
        return copy
    }

    private func uniqueCopyName(basedOn name: String) -> String {
        // Strip a trailing " copy"/" copy N" so duplicating a copy bumps the
        // number instead of stacking "copy copy".
        let root = name.replacing(/\ copy( \d+)?$/, with: "")
        let taken = Set(customProfiles.map(\.name)).union(builtInProfiles.map(\.name))
        guard taken.contains("\(root) copy") else { return "\(root) copy" }
        var n = 2
        while taken.contains("\(root) copy \(n)") { n += 1 }
        return "\(root) copy \(n)"
    }

    // Removes a custom profile. Returns the well-known ID of its base mode's
    // default profile so the coordinator can rewrite references (same VHID
    // identity, stock mapping), or nil if the ID wasn't a stored custom.
    func delete(id: String) -> String? {
        guard let victim = customProfiles.first(where: { $0.id == id }) else { return nil }
        customProfiles.removeAll { $0.id == id }
        persist()
        return MappingProfile.defaultProfileID(forModeID: victim.baseModeID)
    }

    private func builtInProfile(forModeID modeID: String) -> MappingProfile? {
        guard let entry = catalog.entry(id: modeID) else { return nil }
        return MappingProfile(id: MappingProfile.defaultProfileID(forModeID: modeID),
                              name: entry.displayName,
                              baseModeID: modeID)
    }

    private func load() {
        guard let dict = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] else { return }
        customProfiles = dict.values
            .compactMap { try? JSONDecoder().decode(MappingProfile.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        var dict: [String: Data] = [:]
        for profile in customProfiles {
            dict[profile.id] = try? JSONEncoder().encode(profile)
        }
        defaults.set(dict, forKey: Self.defaultsKey)
    }
}
