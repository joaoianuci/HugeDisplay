import AppKit
import CoreGraphics
import Foundation

/// Reconfiguration callback, stored once so the exact same pointer can be unregistered in `deinit`.
/// Must not capture anything: the service travels through the context pointer.
private let toggleReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, ctx in
    // Ignore the "begin" phase; inspect once the change has landed.
    guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
    let service = Unmanaged<DisplayToggleService>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { service.recoverIfNeeded() }
    }
}

/// Enables/disables displays through SkyLight's private `CGSConfigureDisplayEnabled`.
///
/// Safety model:
/// - Changes are per login session (a reboot re-enables everything).
/// - Everything HugeDisplay disables is persisted (id + key + name) because a disabled display vanishes from
///   every system list; it is restored on quit, SIGTERM/SIGINT, next launch (`restoreAll()`, idempotent),
///   or automatically when no usable display is left.
///
/// The service is meant to live as long as the app; the reconfiguration callback holds an unretained pointer
/// that is unregistered in `deinit`.
@MainActor
public final class DisplayToggleService: DisplayToggleServicing {
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    private unowned let manager: DisplayManager
    private let store: DisabledDisplayStore
    private let configureEnabled: ConfigureEnabled?
    private var signalSources: [DispatchSourceSignal] = []

    public init(manager: DisplayManager, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.store = DisabledDisplayStore(defaults: defaults)
        self.configureEnabled =
            PrivateSymbol.load("CGSConfigureDisplayEnabled", from: PrivateSymbol.skyLight, as: ConfigureEnabled.self)
            ?? PrivateSymbol.load("SLSConfigureDisplayEnabled", from: PrivateSymbol.skyLight, as: ConfigureEnabled.self)
        installSignalHandlers()
        registerReconfigurationCallback()
        // Let the manager list displays we disabled (resolved by key against the online list), also after a relaunch.
        manager.disabledProvider = { [weak self] in self?.disabledForDisplay() ?? [] }
        manager.refresh()
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(toggleReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        for source in signalSources { source.cancel() }
    }

    public var isAvailable: Bool { configureEnabled != nil }

    /// True when a previous run left displays disabled (e.g. it crashed). The app should call `restoreAll()` on launch.
    public var hasPendingRestore: Bool { !store.all.isEmpty }

    public func setEnabled(_ enabled: Bool, display id: CGDirectDisplayID) throws {
        guard isAvailable else {
            throw HugeDisplayError.privateAPIUnavailable("Turning displays on or off isn't supported on this version of macOS.")
        }
        if enabled {
            try enable(id)
            return
        }

        let active = Self.activeIDs()
        if case .refused(let reason) = TogglePolicy.canDisable(
            target: id,
            active: active.map(ToggleDisplayInfo.current),
            online: Self.onlineIDs()
        ) {
            throw HugeDisplayError.refused(reason)
        }
        // Persist first (with what only the live display can tell us): once it is off, the system forgets it.
        let entry = DisabledDisplay(
            id: id, key: DisplayKey(id),
            name: manager.displays.first(where: { $0.id == id })?.name,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            disabledAt: Date()
        )
        manager.markDisabled(id)
        store.add(entry)
        do {
            try configure(id, enabled: false)
        } catch {
            store.remove(entry)
            manager.forgetDisabled(id)
            throw error
        }
        manager.refresh()
    }

    /// Re-enables every display HugeDisplay disabled, built-in first. Idempotent; entries that couldn't be
    /// brought back stay stored so the menu can retry them.
    /// Call from applicationWillTerminate and on launch after a crash.
    public func restoreAll() {
        reconcileStore()
        let entries = store.all
        guard !entries.isEmpty else { return }
        let ordered = entries.filter { $0.isBuiltin == true } + entries.filter { $0.isBuiltin != true }
        for entry in ordered {
            try? reenable(entry)
        }
        manager.refresh()
    }

    // MARK: - Private

    private func enable(_ id: CGDirectDisplayID) throws {
        let entry = store.all.first(where: { $0.id == id }) ?? DisabledDisplay(id: id, key: DisplayKey(id))
        do {
            try reenable(entry)
        } catch {
            manager.refresh()
            throw error
        }
        manager.refresh()
    }

    /// Re-enables by the id it had when we turned it off (a disabled display isn't in any list to look up),
    /// and only forgets the entry once the display is really active again.
    private func reenable(_ entry: DisabledDisplay) throws {
        if !Self.activeIDs().contains(entry.id) {
            try configure(entry.id, enabled: true)
        }
        guard Self.activeIDs().contains(entry.id) else {
            throw HugeDisplayError.operationFailed("macOS didn't bring the display back. Please try again.")
        }
        store.remove(entry)
        manager.forgetDisabled(entry.id)
    }

    private func configure(_ id: CGDirectDisplayID, enabled: Bool) throws {
        guard let configureEnabled else {
            throw HugeDisplayError.privateAPIUnavailable("Turning displays on or off isn't supported on this version of macOS.")
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw HugeDisplayError.operationFailed("Couldn't start the display change. Please try again.")
        }
        guard configureEnabled(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            throw HugeDisplayError.operationFailed("macOS refused to turn the display \(enabled ? "on" : "off").")
        }
        // .forSession: measured on macOS 27, WindowServer does NOT revert .forAppOnly when the process exits,
        // so it buys no safety. Recovery is ours: restore on quit/signals/launch; a reboot re-enables everything.
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            throw HugeDisplayError.operationFailed("macOS couldn't apply the display change.")
        }
    }

    /// What the manager lists as disabled: stored entries that aren't active.
    private func disabledForDisplay() -> [DisabledDisplay] {
        let active = Set(Self.activeIDs())
        return store.all.filter { !active.contains($0.id) }
    }

    /// Drops entries whose display is active again, and entries from before the last boot
    /// (changes are per session, so a reboot already brought those displays back and their ids are stale).
    private func reconcileStore() {
        let entries = store.all
        guard !entries.isEmpty else { return }
        let active = Set(Self.activeIDs())
        let bootTime = Self.bootTime()
        store.replaceAll(entries.filter { entry in
            guard !active.contains(entry.id) else { return false }
            if let bootTime, let at = entry.disabledAt, at < bootTime { return false }
            return true
        })
    }

    /// Called after every display reconfiguration: if nothing usable is left on screen, bring our displays back.
    fileprivate func recoverIfNeeded() {
        reconcileStore()
        let disabledByUs = Set(store.all.map(\.id))
        guard !disabledByUs.isEmpty else { return }
        if TogglePolicy.needsRecovery(active: Self.activeIDs().map(ToggleDisplayInfo.current), disabledByUs: disabledByUs) {
            restoreAll()
        }
    }

    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN) // let the dispatch source own the signal
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.restoreAll()
                    // Prefer a normal termination so applicationWillTerminate and other hooks run.
                    if let app = NSApp { app.terminate(nil) } else { exit(0) }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func registerReconfigurationCallback() {
        CGDisplayRegisterReconfigurationCallback(toggleReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private static func activeIDs() -> [CGDirectDisplayID] {
        list(CGGetActiveDisplayList)
    }

    private static func onlineIDs() -> [CGDirectDisplayID] {
        list(CGGetOnlineDisplayList)
    }

    private static func list(_ fetch: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard fetch(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard fetch(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
