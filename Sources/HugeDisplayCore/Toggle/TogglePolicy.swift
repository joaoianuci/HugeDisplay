import CoreGraphics
import Foundation

/// A display HugeDisplay switched off. The id is only valid within a login session
/// (it can change after reboot/replug), so the stable key is stored alongside it.
public struct DisabledDisplay: Codable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let key: DisplayKey

    public init(id: CGDirectDisplayID, key: DisplayKey) {
        self.id = id
        self.key = key
    }
}

/// Pure decision logic for enabling/disabling displays. No CoreGraphics calls, so it is unit-testable.
public enum TogglePolicy {
    public enum Decision: Equatable, Sendable {
        case allowed
        case refused(String)
    }

    /// `active` and `online` are the CoreGraphics active/online display lists at the time of the request.
    public static func canDisable(
        target: CGDirectDisplayID,
        active: [CGDirectDisplayID],
        online: [CGDirectDisplayID]
    ) -> Decision {
        guard online.contains(target) else {
            return .refused("That display isn't connected anymore.")
        }
        guard active.contains(target) else {
            return .refused("That display is already turned off.")
        }
        guard active.contains(where: { $0 != target }) else {
            return .refused("You can't turn off your only active display.")
        }
        return .allowed
    }

    /// True when nothing usable is left on screen even though we switched some display off,
    /// e.g. the external was unplugged while the built-in was disabled.
    public static func needsRecovery(
        active: [CGDirectDisplayID],
        online: [CGDirectDisplayID],
        disabledByUs: Set<CGDirectDisplayID>
    ) -> Bool {
        guard !disabledByUs.isEmpty else { return false }
        if active.isEmpty { return true }
        return online.allSatisfy { disabledByUs.contains($0) }
    }

    /// Finds the current id of a display we disabled: same id with the same key, else any online display with that key.
    public static func resolveID(
        for entry: DisabledDisplay,
        online: [(id: CGDirectDisplayID, key: DisplayKey)]
    ) -> CGDirectDisplayID? {
        if let same = online.first(where: { $0.id == entry.id && $0.key == entry.key }) { return same.id }
        return online.first(where: { $0.key == entry.key })?.id
    }
}

/// Persists which displays HugeDisplay disabled so they can be restored after a crash.
public final class DisabledDisplayStore {
    public static let defaultsKey = "disabledDisplays"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var all: [DisabledDisplay] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([DisabledDisplay].self, from: data) else { return [] }
        return list
    }

    public func add(_ entry: DisabledDisplay) {
        var list = all.filter { $0.id != entry.id && $0.key != entry.key }
        list.append(entry)
        save(list)
    }

    public func remove(id: CGDirectDisplayID) {
        save(all.filter { $0.id != id })
    }

    private func save(_ list: [DisabledDisplay]) {
        if list.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
