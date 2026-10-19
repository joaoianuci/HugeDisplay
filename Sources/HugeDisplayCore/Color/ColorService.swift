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
        return Self.sortedAndDeduped(entries).map { ColorPreset(id: $0.path, name: $0.name) }
    }

    public func currentPreset(for display: CGDirectDisplayID) -> ColorPreset? {
        guard let info = Self.deviceInfo(for: display) else { return nil }
        let factory = Self.factoryProfiles(in: info)
        let url = Self.customProfileURL(in: info)
            ?? factory.first(where: { $0.isDefault })?.url
            ?? factory.first?.url
        guard let url else { return nil }
        return ColorPreset(id: url.path, name: Self.profileDescription(at: url) ?? url.deletingPathExtension().lastPathComponent)
    }

    public func apply(_ preset: ColorPreset, to display: CGDirectDisplayID) throws {
        guard FileManager.default.fileExists(atPath: preset.id) else {
            throw HugeDisplayError.operationFailed("Color profile not found: \(preset.name)")
        }
        guard let uuid = Self.deviceUUID(for: display) else {
            throw HugeDisplayError.operationFailed("Could not identify display \(display) for ColorSync")
        }
        let url = URL(fileURLWithPath: preset.id)
        let profiles: [CFString: Any] = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue(): url]
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

    /// Factory profiles first, then alphabetical (case-insensitive); entries with the same name
    /// are collapsed, and a factory entry always wins over an installed one.
    nonisolated static func sortedAndDeduped(_ entries: [ProfileEntry]) -> [ProfileEntry] {
        var seen = Set<String>()
        var unique: [ProfileEntry] = []
        for e in entries.sorted(by: { $0.isFactory && !$1.isFactory }) where seen.insert(e.name.lowercased()).inserted {
            unique.append(e)
        }
        return unique.sorted { a, b in
            if a.isFactory != b.isFactory { return a.isFactory }
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            return c == .orderedSame ? a.path < b.path : c == .orderedAscending
        }
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
        return (info[defaultKey] as? String) ?? (factory?[defaultKey] as? String)
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

    private static func customProfileURL(in info: [String: Any]) -> URL? {
        guard let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any], !custom.isEmpty else { return nil }
        if let id = defaultModeID(in: info), let u = url(from: custom[id]) { return u }
        if let u = url(from: custom[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String]) { return u }
        return custom.sorted(by: { $0.key < $1.key }).lazy.compactMap { url(from: $0.value) }.first
    }
}
