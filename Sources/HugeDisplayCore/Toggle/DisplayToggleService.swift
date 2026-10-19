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
/// - The change is applied `.forAppOnly`, so WindowServer reverts it by itself if this process dies (crash, SIGKILL).
/// - Everything HugeDisplay disables is also persisted (by `DisplayKey`) as a secondary net: on quit, SIGTERM/SIGINT,
///   on next launch (`restoreAll()`, idempotent), or automatically when no usable display is left.
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
        // Persist first: if we crash right after the call, the next launch can still restore it.
        let entry = DisabledDisplay(id: id, key: DisplayKey(id))
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

    /// Re-enables every display HugeDisplay disabled. Idempotent: entries whose display is already active are
    /// just dropped, and calling it with nothing stored does nothing.
    /// Call from applicationWillTerminate and on launch after a crash.
    public func restoreAll() {
        let entries = store.all
        guard !entries.isEmpty else { return }
        let resolutions = TogglePolicy.resolveAll(entries, online: Self.onlineDisplays(), active: Set(Self.activeIDs()))

        var pending: [(entry: DisabledDisplay, target: CGDirectDisplayID)] = []
        for r in resolutions {
            switch r.status {
            case .active, .duplicate: store.remove(r.entry) // already back (e.g. WindowServer reverted it after a crash)
            case .offline: break // not connected: keep it so a later attempt can retry
            case .inactive(let target): pending.append((r.entry, target))
            }
        }
        // Built-in first: it is the display the user is most likely stuck without.
        let ordered = pending.filter { CGDisplayIsBuiltin($0.target) != 0 } + pending.filter { CGDisplayIsBuiltin($0.target) == 0 }
        for item in ordered {
            do {
                try configure(item.target, enabled: true)
            } catch {
                continue // keep it persisted so a later attempt can retry
            }
            guard Self.activeIDs().contains(item.target) else { continue }
            store.remove(item.entry)
            manager.forgetDisabled(item.entry.id)
            manager.forgetDisabled(item.target)
        }
        manager.refresh()
    }

    // MARK: - Private

    /// Resolves by `DisplayKey` (the id the UI holds may be stale) and only forgets the stored entry
    /// once the display is seen in the active list.
    private func enable(_ id: CGDirectDisplayID) throws {
        let online = Self.onlineDisplays()
        let entries = store.all
        let key: DisplayKey
        if let current = online.first(where: { $0.id == id }) {
            key = current.key
        } else if let known = entries.first(where: { $0.id == id })?.key ?? manager.displays.first(where: { $0.id == id })?.key {
            key = known
        } else {
            throw HugeDisplayError.refused("That display isn't connected anymore.")
        }
        let entry = entries.first(where: { $0.key == key && $0.id == id })
            ?? entries.first(where: { $0.key == key })
            ?? DisabledDisplay(id: id, key: key)
        let active = Set(Self.activeIDs())
        guard let target = TogglePolicy.resolveID(for: entry, online: online, active: active) else {
            throw HugeDisplayError.refused("That display isn't connected anymore.")
        }
        if !active.contains(target) {
            try configure(target, enabled: true)
            guard Self.activeIDs().contains(target) else {
                // Keep the stored entry: it is only dropped once the display is really active.
                manager.refresh()
                throw HugeDisplayError.operationFailed("macOS didn't bring the display back. Please try again.")
            }
        }
        store.remove(entry)
        manager.forgetDisabled(id)
        manager.forgetDisabled(target)
        manager.refresh()
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
        // .forAppOnly: WindowServer reverts the change if this process dies, so a crash can't leave displays off.
        guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success else {
            throw HugeDisplayError.operationFailed("macOS couldn't apply the display change.")
        }
    }

    /// What the manager lists as disabled: stored entries that are online but not active, with their current ids.
    private func disabledForDisplay() -> [(DisplayKey, CGDirectDisplayID?)] {
        let resolutions = TogglePolicy.resolveAll(store.all, online: Self.onlineDisplays(), active: Set(Self.activeIDs()))
        return resolutions.compactMap { r in
            if case .inactive(let id) = r.status { return (r.entry.key, id) }
            return nil
        }
    }

    /// Drops stored entries whose display is back in the active list and refreshes ids of the rest.
    private func reconcileStore() {
        let entries = store.all
        guard !entries.isEmpty else { return }
        store.replaceAll(TogglePolicy.reconciled(entries, online: Self.onlineDisplays(), active: Set(Self.activeIDs())))
    }

    /// Called after every display reconfiguration: if nothing usable is left on screen, bring our displays back.
    fileprivate func recoverIfNeeded() {
        reconcileStore()
        let entries = store.all
        guard !entries.isEmpty else { return }
        let resolutions = TogglePolicy.resolveAll(entries, online: Self.onlineDisplays(), active: Set(Self.activeIDs()))
        let disabledOnline = Set(resolutions.compactMap { r -> CGDirectDisplayID? in
            if case .inactive(let id) = r.status { return id }
            return nil
        })
        if TogglePolicy.needsRecovery(active: Self.activeIDs().map(ToggleDisplayInfo.current), disabledByUs: disabledOnline) {
            restoreAll()
        }
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

    private static func onlineDisplays() -> [(id: CGDirectDisplayID, key: DisplayKey)] {
        onlineIDs().map { (id: $0, key: DisplayKey($0)) }
    }

    private static func list(_ fetch: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard fetch(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard fetch(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
