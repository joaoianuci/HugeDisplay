import CoreGraphics
import Foundation

/// Enables/disables displays through SkyLight's private `CGSConfigureDisplayEnabled`.
/// Everything HugeDisplay disables is persisted so it can be put back on quit, on SIGTERM/SIGINT,
/// on next launch after a crash (call `restoreAll()`), or automatically when no usable display is left.
/// The service is meant to live as long as the app (the reconfiguration callback holds an unretained pointer).
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
    }

    public var isAvailable: Bool { configureEnabled != nil }

    /// True when a previous run left displays disabled (e.g. it crashed). The app should call `restoreAll()` on launch.
    public var hasPendingRestore: Bool { !store.all.isEmpty }

    public func setEnabled(_ enabled: Bool, display id: CGDirectDisplayID) throws {
        guard isAvailable else {
            throw HugeDisplayError.privateAPIUnavailable("Turning displays on or off isn't supported on this version of macOS.")
        }
        if enabled {
            try configure(id, enabled: true)
            store.remove(id: id)
            manager.forgetDisabled(id)
            manager.refresh()
            return
        }

        if case .refused(let reason) = TogglePolicy.canDisable(target: id, active: Self.activeIDs(), online: Self.onlineIDs()) {
            throw HugeDisplayError.refused(reason)
        }
        // Persist first: if we crash right after the call, the next launch can still restore it.
        manager.markDisabled(id)
        store.add(DisabledDisplay(id: id, key: DisplayKey(id)))
        do {
            try configure(id, enabled: false)
        } catch {
            store.remove(id: id)
            manager.forgetDisabled(id)
            throw error
        }
        manager.refresh()
    }

    /// Re-enables every display HugeDisplay disabled. Safe to call repeatedly; does nothing when there is nothing to restore.
    /// Call from applicationWillTerminate and on launch after a crash.
    public func restoreAll() {
        let entries = store.all
        guard !entries.isEmpty else { return }
        let online = Self.onlineIDs().map { (id: $0, key: DisplayKey($0)) }
        // Built-in first: it is the display the user is most likely stuck without.
        let ordered = entries.filter { CGDisplayIsBuiltin($0.id) != 0 } + entries.filter { CGDisplayIsBuiltin($0.id) == 0 }
        for entry in ordered {
            let target = TogglePolicy.resolveID(for: entry, online: online) ?? entry.id
            do {
                try configure(target, enabled: true)
            } catch {
                continue // keep it persisted so a later attempt can retry
            }
            store.remove(id: entry.id)
            manager.forgetDisabled(entry.id)
            manager.forgetDisabled(target)
        }
        manager.refresh()
    }

    // MARK: - Private

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
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            throw HugeDisplayError.operationFailed("macOS couldn't apply the display change.")
        }
    }

    /// Called after every display reconfiguration: if nothing usable is left on screen, bring our displays back.
    fileprivate func recoverIfNeeded() {
        let entries = store.all
        guard !entries.isEmpty else { return }
        if TogglePolicy.needsRecovery(active: Self.activeIDs(), online: Self.onlineIDs(), disabledByUs: Set(entries.map(\.id))) {
            restoreAll()
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN) // let the dispatch source own the signal
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.restoreAll() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func registerReconfigurationCallback() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            // Ignore the "begin" phase; inspect once the change has landed.
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            let service = Unmanaged<DisplayToggleService>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { service.recoverIfNeeded() }
            }
        }, ctx)
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
