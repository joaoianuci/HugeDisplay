import ColorSync
import CoreGraphics
import Foundation

/// Per-display color presets implemented as ColorSync profile switching (the same mechanism
/// as System Settings / BetterDisplay). Persistent across app exit because ColorSync stores it.
@MainActor
public final class ColorService: ColorServicing {
    /// Installed display-class RGB profiles, scanned once per process (see `reloadProfiles()`).
    private var installedCache: [ProfileEntry]?

    public init() {}

    /// Drops the cached profile scan; the next `presets(for:)` call rescans the profile folders.
    public func reloadProfiles() {
        installedCache = nil
    }

    public func presets(for display: CGDirectDisplayID) -> [ColorPreset] {
        var entries = factoryEntries(for: display)
        entries.append(contentsOf: installedProfiles())
        let current = Self.deviceInfo(for: display).flatMap { Self.currentProfileURL(in: $0) }
        // The applied profile may live outside the scanned folders; the picker must still be able to show it.
        if let current, !entries.contains(where: { $0.path == current.path }) {
            entries.append(ProfileEntry(path: current.path, name: Self.profileDescription(at: current) ?? current.deletingPathExtension().lastPathComponent, isFactory: false))
        }
        return Self.sortedAndDeduped(entries, keeping: current?.path).map { ColorPreset(id: $0.path, name: $0.name) }
    }

    /// Always an element of `presets(for:)` (same id), so a picker selection bound to it never goes blank.
    public func currentPreset(for display: CGDirectDisplayID) -> ColorPreset? {
        guard let info = Self.deviceInfo(for: display) else { return nil }
        let url = Self.currentProfileURL(in: info)
        guard let url else { return nil }
        return presets(for: display).first { $0.id == url.path }
    }

    public func apply(_ preset: ColorPreset, to display: CGDirectDisplayID) throws {
        guard FileManager.default.fileExists(atPath: preset.id) else {
            throw HugeDisplayError.operationFailed("Color profile not found: \(preset.name)")
        }
        guard let uuid = Self.deviceUUID(for: display) else {
            throw HugeDisplayError.operationFailed("Could not identify display \(display) for ColorSync")
        }
        let url = URL(fileURLWithPath: preset.id)
        let info = Self.deviceInfo(for: display)
        let keys = Self.profileKeys(
            defaultModeID: info.flatMap { Self.defaultModeID(in: $0) },
            customKeys: info.map { Self.customModeIDs(in: $0) } ?? []
        )
        var profiles: [CFString: Any] = [:]
        for key in keys { profiles[key as CFString] = url }
        let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, profiles as CFDictionary)
        guard ok else {
            throw HugeDisplayError.operationFailed("ColorSync refused profile \"\(preset.name)\" for display \(display)")
        }
    }

    // MARK: - Pure helpers (unit-tested)

    struct ProfileEntry: Hashable {
        var path: String
        var name: String
        var isFactory: Bool
    }

    /// Factory profiles first, then alphabetical (case-insensitive). Entries with the same path or the same
    /// name are collapsed. The winner of a name clash is the entry at `keeping` (the currently applied
    /// profile), otherwise a factory entry, otherwise the first one seen.
    nonisolated static func sortedAndDeduped(_ entries: [ProfileEntry], keeping currentPath: String? = nil) -> [ProfileEntry] {
        func rank(_ e: ProfileEntry) -> Int { e.path == currentPath ? 0 : (e.isFactory ? 1 : 2) }
        var seenPaths = Set<String>()
        var seenNames = Set<String>()
        var unique: [ProfileEntry] = []
        // `sorted` is not stable, so break ties by original index.
        let ranked = entries.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        for (_, e) in ranked where seenPaths.insert(e.path).inserted && seenNames.insert(e.name.lowercased()).inserted {
            unique.append(e)
        }
        return unique.sorted { a, b in
            if a.isFactory != b.isFactory { return a.isFactory }
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            return c == .orderedSame ? a.path < b.path : c == .orderedAscending
        }
    }

    /// ColorSync mode keys to write a profile under: the default mode first, then every mode that currently
    /// holds a custom profile (the LG keeps its override under "HDMI HD", not under the generic default key).
    /// Falls back to `kColorSyncDeviceDefaultProfileID` when nothing is known about the device.
    nonisolated static func profileKeys(defaultModeID: String?, customKeys: [String]) -> [String] {
        var keys: [String] = []
        for k in [defaultModeID].compactMap({ $0 }) + customKeys.sorted() where !keys.contains(k) { keys.append(k) }
        return keys.isEmpty ? [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] : keys
    }

    // MARK: - ColorSync access

    private struct FactoryProfile {
        var modeID: String
        var url: URL
        var isDefault: Bool
    }

    private func factoryEntries(for display: CGDirectDisplayID) -> [ProfileEntry] {
        guard let info = Self.deviceInfo(for: display) else { return [] }
        return Self.factoryProfiles(in: info).map {
            ProfileEntry(path: $0.url.path, name: Self.profileDescription(at: $0.url) ?? $0.url.deletingPathExtension().lastPathComponent, isFactory: true)
        }
    }

    private func installedProfiles() -> [ProfileEntry] {
        if let installedCache { return installedCache }
        let scanned = Self.scanInstalledProfiles()
        installedCache = scanned
        return scanned
    }

    private static var searchFolders: [URL] {
        [
            URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles"),
            URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
        ]
    }

    /// Scans profile folders (recursively) for display-class RGB profiles. Per-display factory
    /// profiles (".../Displays/") are skipped here; they come from the device info of their display.
    private static func scanInstalledProfiles() -> [ProfileEntry] {
        var result: [ProfileEntry] = []
        for folder in searchFolders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard ["icc", "icm"].contains(url.pathExtension.lowercased()) else { continue }
                if url.deletingLastPathComponent().lastPathComponent == "Displays" { continue }
                guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
                      isDisplayRGB(profile), let name = description(of: profile) else { continue }
                result.append(ProfileEntry(path: url.path, name: name, isFactory: false))
            }
        }
        return result
    }

    /// ICC header: bytes 12..<16 device class, 16..<20 data color space. ColorSync returns the
    /// header with its 32-bit words in host (little-endian) order, so each tag is reversed.
    private static func isDisplayRGB(_ profile: ColorSyncProfile) -> Bool {
        guard let data = ColorSyncProfileCopyHeader(profile)?.takeRetainedValue() as Data?, data.count >= 20 else { return false }
        func tag(_ r: Range<Int>) -> String { String(decoding: data[r].reversed(), as: UTF8.self) }
        return tag(12..<16) == "mntr" && tag(16..<20) == "RGB "
    }

    private static func description(of profile: ColorSyncProfile) -> String? {
        guard let s = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    private static func profileDescription(at url: URL) -> String? {
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return description(of: profile)
    }

    private static func deviceUUID(for display: CGDirectDisplayID) -> CFUUID? {
        CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue()
    }

    private static func deviceInfo(for display: CGDirectDisplayID) -> [String: Any]? {
        guard let uuid = deviceUUID(for: display),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue()
        else { return nil }
        return info as? [String: Any]
    }

    private static func url(from value: Any?) -> URL? {
        if let u = value as? URL { return u }
        if let s = value as? String { return URL(fileURLWithPath: s) }
        return nil
    }

    /// The default mode ID lives in the device info; accept it inside the factory dict too.
    private static func defaultModeID(in info: [String: Any]) -> String? {
        let defaultKey = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any]
        if let id = (info[defaultKey] as? String) ?? (factory?[defaultKey] as? String) { return id }
        // Single factory mode: that is the default by definition.
        let modes = (factory ?? [:]).filter { $0.value is [String: Any] }
        return modes.count == 1 ? modes.keys.first : nil
    }

    private static func factoryProfiles(in info: [String: Any]) -> [FactoryProfile] {
        let urlKey = kColorSyncDeviceProfileURL.takeUnretainedValue() as String
        guard let modes = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any] else { return [] }
        let defaultID = defaultModeID(in: info)
        var result: [FactoryProfile] = []
        for (modeID, value) in modes.sorted(by: { $0.key < $1.key }) {
            guard let dict = value as? [String: Any], let url = url(from: dict[urlKey]) else { continue }
            result.append(FactoryProfile(modeID: modeID, url: url, isDefault: modeID == defaultID))
        }
        return result
    }

    private static func customModeIDs(in info: [String: Any]) -> [String] {
        let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any]
        return custom.map { Array($0.keys) } ?? []
    }

    /// Effective profile: the custom override if present, else the factory profile of the default mode.
    private static func currentProfileURL(in info: [String: Any]) -> URL? {
        let factory = factoryProfiles(in: info)
        return customProfileURL(in: info) ?? factory.first(where: { $0.isDefault })?.url ?? factory.first?.url
    }

    private static func customProfileURL(in info: [String: Any]) -> URL? {
        guard let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any], !custom.isEmpty else { return nil }
        if let id = defaultModeID(in: info), let u = url(from: custom[id]) { return u }
        if let u = url(from: custom[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String]) { return u }
        return custom.sorted(by: { $0.key < $1.key }).lazy.compactMap { url(from: $0.value) }.first
    }
}
