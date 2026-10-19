import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Picture-in-picture of a whole display in a floating panel, fed by ScreenCaptureKit and drawn
/// zero-copy (IOSurface -> CALayer). Idle cost is a few windows and no capture when nothing is shown.
@MainActor
public final class PIPService: PIPServicing {
    private let defaults: UserDefaults
    private var sessions: [CGDirectDisplayID: PIPSession] = [:]
    private var starting: Set<CGDirectDisplayID> = []
    /// Sources that should be reopened at next launch. Entries for displays that are currently
    /// unplugged or failed to start are kept until the user closes that PIP.
    private var openKeys: [DisplayKey]

    private static let openKeysDefaultsKey = "HugeDisplay.pip.open"
    private static func settingsDefaultsKey(_ key: DisplayKey) -> String { "HugeDisplay.pip.settings.\(key)" }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openKeys = defaults.data(forKey: Self.openKeysDefaultsKey)
            .flatMap { try? JSONDecoder().decode([DisplayKey].self, from: $0) } ?? []
    }

    // MARK: - PIPServicing

    public var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    public func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    public var activeSources: [CGDirectDisplayID] { sessions.keys.sorted() }

    public func isShowing(source display: CGDirectDisplayID) -> Bool { sessions[display] != nil }

    public func show(source display: CGDirectDisplayID) async throws {
        guard hasPermission else { throw Self.permissionError }
        if let existing = sessions[display] {
            existing.bringToFront()
            return
        }
        guard starting.insert(display).inserted else { return }
        defer { starting.remove(display) }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch let error as NSError where error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue {
            throw Self.permissionError
        } catch {
            throw HugeDisplayError.operationFailed("Could not list displays for capture: \(error.localizedDescription)")
        }
        guard let source = content.displays.first(where: { $0.displayID == display }) else {
            throw HugeDisplayError.operationFailed("Display \(display) is not available for capture (disabled or disconnected).")
        }
        guard sessions[display] == nil else { return }

        let key = DisplayKey(display)
        let session = PIPSession(display: display, key: key, filter: Self.filter(for: source, content: content), settings: loadSettings(key))
        session.onSettingsChanged = { [weak self] key, settings in self?.saveSettings(settings, for: key) }
        // The panel's own close button reports CancellationError: that is an explicit user close (forget the PIP).
        // Any other error is a stream failure: tear down but keep the key so displaysChanged() can reopen it.
        session.onFailure = { [weak self] id, error in
            if error is CancellationError { self?.close(source: id) } else { self?.tearDown(source: id) }
        }
        sessions[display] = session

        if !openKeys.contains(key) {
            openKeys.append(key)
            saveOpenKeys()
        }
    }

    /// Explicit user close: ends the session and forgets the PIP.
    public func close(source display: CGDirectDisplayID) {
        guard let session = sessions.removeValue(forKey: display) else { return }
        session.close()
        openKeys.removeAll { $0 == session.key }
        saveOpenKeys()
    }

    /// Ends the session but keeps its key in `openKeys` so it can come back (display off, sleep, replug).
    private func tearDown(source display: CGDirectDisplayID) {
        sessions.removeValue(forKey: display)?.close()
    }

    /// Call on display-list changes: closes sessions whose source is no longer active (keeping their keys) and
    /// reopens remembered PIPs whose display is active again. Never prompts: does nothing without permission.
    public func displaysChanged() async {
        let active = Self.activeDisplayIDs()
        for id in sessions.keys where !active.contains(id) { tearDown(source: id) }
        guard hasPermission else { return }
        for key in openKeys {
            guard let id = active.first(where: { DisplayKey($0) == key }), sessions[id] == nil else { continue }
            try? await show(source: id)
        }
    }

    // MARK: - Panel options

    public func setClickThrough(_ on: Bool, source display: CGDirectDisplayID) {
        if let session = sessions[display] {
            session.setClickThrough(on)
        } else {
            var settings = loadSettings(DisplayKey(display))
            settings.clickThrough = on
            saveSettings(settings, for: DisplayKey(display))
        }
    }

    public func isClickThrough(source display: CGDirectDisplayID) -> Bool {
        sessions[display]?.settings.clickThrough ?? loadSettings(DisplayKey(display)).clickThrough
    }

    /// 0.5, 0.75 or 1 (other values snap to the nearest).
    public func setOpacity(_ value: Double, source display: CGDirectDisplayID) {
        if let session = sessions[display] {
            session.setOpacity(value)
        } else {
            var settings = loadSettings(DisplayKey(display))
            settings.opacity = PIPGeometry.snapOpacity(value)
            saveSettings(settings, for: DisplayKey(display))
        }
    }

    public func opacity(source display: CGDirectDisplayID) -> Double {
        sessions[display]?.settings.opacity ?? loadSettings(DisplayKey(display)).opacity
    }

    // MARK: - Session restore

    /// Reopens the PIPs that were open at last quit. Never prompts: does nothing without permission.
    public func restoreLastSession() async {
        guard hasPermission else { return }
        let active = Self.activeDisplayIDs()
        for key in openKeys {
            guard let id = active.first(where: { DisplayKey($0) == key }), sessions[id] == nil else { continue }
            try? await show(source: id)
        }
    }

    // MARK: - Private

    private static var permissionError: HugeDisplayError {
        .refused("Screen Recording permission required. Allow HugeDisplay in System Settings > Privacy & Security > Screen & System Audio Recording, then try again.")
    }

    /// Excludes HugeDisplay's own windows so a PIP can never capture itself (the panel also opts out via sharingType).
    private static func filter(for display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let app = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
        }
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        return SCContentFilter(display: display, excludingWindows: own)
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func loadSettings(_ key: DisplayKey) -> PIPSettings {
        defaults.data(forKey: Self.settingsDefaultsKey(key))
            .flatMap { try? JSONDecoder().decode(PIPSettings.self, from: $0) } ?? PIPSettings()
    }

    private func saveSettings(_ settings: PIPSettings, for key: DisplayKey) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsDefaultsKey(key))
        }
    }

    private func saveOpenKeys() {
        if let data = try? JSONEncoder().encode(openKeys) {
            defaults.set(data, forKey: Self.openKeysDefaultsKey)
        }
    }
}
