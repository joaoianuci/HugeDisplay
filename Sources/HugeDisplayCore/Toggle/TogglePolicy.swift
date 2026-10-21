import CoreGraphics
import Foundation

/// A display HugeDisplay switched off.
///
/// Measured on macOS 27 / M5: a disabled display disappears from every display list (CG online/active and
/// SkyLight's), but re-enabling it with the same CGDirectDisplayID works. So the id is what we re-enable with;
/// the key, name and built-in flag are kept because the system can no longer tell us about it while it is off.
public struct DisabledDisplay: Codable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let key: DisplayKey
    public var name: String?
    public var isBuiltin: Bool?
    public var disabledAt: Date?

    public init(id: CGDirectDisplayID, key: DisplayKey, name: String? = nil, isBuiltin: Bool? = nil, disabledAt: Date? = nil) {
        self.id = id
        self.key = key
        self.name = name
        self.isBuiltin = isBuiltin
        self.disabledAt = disabledAt
    }

    // Identity is (id, key); the descriptive fields don't make two entries different.
    public static func == (a: DisabledDisplay, b: DisabledDisplay) -> Bool { a.id == b.id && a.key == b.key }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(key)
    }
}

/// What the toggle policy needs to know about one active display. A plain value so the policy stays pure.
public struct ToggleDisplayInfo: Equatable, Sendable {
    public let id: CGDirectDisplayID
    /// Reports a physical panel size (virtual displays, AirPlay/Sidecar report none).
    public let isPhysical: Bool
    /// Mirrors another display (it adds no extra screen for the user).
    public let isMirror: Bool
    public let isAsleep: Bool

    public init(id: CGDirectDisplayID, isPhysical: Bool = true, isMirror: Bool = false, isAsleep: Bool = false) {
        self.id = id
        self.isPhysical = isPhysical
        self.isMirror = isMirror
        self.isAsleep = isAsleep
    }

    /// A display the user can actually see and work on.
    public var isUsable: Bool { isPhysical && !isMirror && !isAsleep }

    /// Reads the live CoreGraphics state for `id`.
    public static func current(_ id: CGDirectDisplayID) -> ToggleDisplayInfo {
        ToggleDisplayInfo(
            id: id,
            isPhysical: CGDisplayScreenSize(id) != .zero,
            isMirror: CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay,
            isAsleep: CGDisplayIsAsleep(id) != 0
        )
    }
}

/// Pure decision logic for enabling/disabling displays. No CoreGraphics calls, so it is unit-testable.
public enum TogglePolicy {
    public enum Decision: Equatable, Sendable {
        case allowed
        case refused(String)
    }

    /// `active` describes the active displays and `online` is the online id list at the time of the request.
    /// Only physical, visible displays (not virtual, mirrored or asleep) count as "another display".
    public static func canDisable(
        target: CGDirectDisplayID,
        active: [ToggleDisplayInfo],
        online: [CGDirectDisplayID]
    ) -> Decision {
        guard online.contains(target) else {
            return .refused(String(localized: "That display isn't connected anymore.", bundle: .module))
        }
        guard active.contains(where: { $0.id == target }) else {
            return .refused(String(localized: "That display is already turned off.", bundle: .module))
        }
        guard active.contains(where: { $0.id != target && $0.isUsable }) else {
            return .refused(String(localized: "You can't turn off your only active display.", bundle: .module))
        }
        return .allowed
    }

    /// True when we switched some display off and no usable display is left on screen,
    /// e.g. the external was unplugged while the built-in was disabled.
    /// `disabledByUs` are the ids (online right now) of the displays we have switched off.
    public static func needsRecovery(
        active: [ToggleDisplayInfo],
        disabledByUs: Set<CGDirectDisplayID>
    ) -> Bool {
        guard !disabledByUs.isEmpty else { return false }
        // Asleep still counts here: ordinary display sleep must not re-enable a display the user turned off.
        return !active.contains(where: { $0.isPhysical && !$0.isMirror && !disabledByUs.contains($0.id) })
    }

    /// Finds the current id of a display we disabled, matching by key.
    /// Preference: inactive (still needs enabling) with the remembered id, any inactive, then active ones.
    /// `excluding` lets callers hand out one physical display per entry when several share a key.
    public static func resolveID(
        for entry: DisabledDisplay,
        online: [(id: CGDirectDisplayID, key: DisplayKey)],
        active: Set<CGDirectDisplayID> = [],
        excluding: Set<CGDirectDisplayID> = []
    ) -> CGDirectDisplayID? {
        let candidates = online.filter { $0.key == entry.key && !excluding.contains($0.id) }
        return candidates.first(where: { !active.contains($0.id) && $0.id == entry.id })?.id
            ?? candidates.first(where: { !active.contains($0.id) })?.id
            ?? candidates.first(where: { $0.id == entry.id })?.id
            ?? candidates.first?.id
    }

    public struct Resolution: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            /// Online but switched off: needs re-enabling (current id).
            case inactive(CGDirectDisplayID)
            /// Seen in the active list: nothing left to restore.
            case active(CGDirectDisplayID)
            /// Not connected right now.
            case offline
            /// Another entry already claimed the only matching display (stale duplicate).
            case duplicate
        }
        public let entry: DisabledDisplay
        public let status: Status
    }

    /// Resolves every persisted entry against the live display lists by key.
    public static func resolveAll(
        _ entries: [DisabledDisplay],
        online: [(id: CGDirectDisplayID, key: DisplayKey)],
        active: Set<CGDirectDisplayID>
    ) -> [Resolution] {
        var claimed = Set<CGDirectDisplayID>()
        return entries.map { entry in
            guard let target = resolveID(for: entry, online: online, active: active, excluding: claimed) else {
                let isDuplicate = online.contains { $0.key == entry.key }
                return Resolution(entry: entry, status: isDuplicate ? .duplicate : .offline)
            }
            claimed.insert(target)
            return Resolution(entry: entry, status: active.contains(target) ? .active(target) : .inactive(target))
        }
    }

    /// The entries still worth persisting: drops those whose display is seen active (or duplicates of one),
    /// keeps offline ones, and refreshes ids of the rest. Idempotent.
    public static func reconciled(
        _ entries: [DisabledDisplay],
        online: [(id: CGDirectDisplayID, key: DisplayKey)],
        active: Set<CGDirectDisplayID>
    ) -> [DisabledDisplay] {
        resolveAll(entries, online: online, active: active).compactMap { r in
            switch r.status {
            case .active, .duplicate: nil
            case .offline: r.entry
            case .inactive(let id): DisabledDisplay(id: id, key: r.entry.key)
            }
        }
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
        // Entries are identified by (id, key): two identical monitors share a key but not an id.
        var list = all.filter { $0 != entry }
        list.append(entry)
        save(list)
    }

    public func remove(id: CGDirectDisplayID) {
        save(all.filter { $0.id != id })
    }

    public func remove(_ entry: DisabledDisplay) {
        save(all.filter { $0 != entry })
    }

    /// Replaces the stored list; writes only when it changed.
    public func replaceAll(_ entries: [DisabledDisplay]) {
        if entries != all { save(entries) }
    }

    private func save(_ list: [DisabledDisplay]) {
        if list.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
