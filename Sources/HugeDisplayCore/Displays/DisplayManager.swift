import AppKit
import Combine
import CoreGraphics

/// Reconfiguration callback, stored once so the exact same pointer can be unregistered in `deinit`.
/// Must not capture anything: the manager travels through the context pointer.
private let managerReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, ctx in
    // Ignore the "begin" phase; refresh once the change has landed.
    guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            manager.nameCache.removeAll()
            manager.refresh()
        }
    }
}

/// Source of truth for the display list. Event-driven: refreshes only on CoreGraphics
/// reconfiguration callbacks (no polling), which keeps idle CPU at ~0.
@MainActor
public final class DisplayManager: ObservableObject {
    @Published public private(set) var displays: [Display] = []

    /// Set by the toggle service: displays HugeDisplay switched off. Listed on every refresh even though the
    /// system no longer reports them, so they can be re-enabled from the menu, also after an app relaunch.
    public var disabledProvider: (@MainActor () -> [DisabledDisplay])?

    /// Displays disabled in this run (see `markDisabled`); kept until they show up as active again.
    private var disabled: [CGDirectDisplayID: Display] = [:]
    fileprivate var nameCache: [CGDirectDisplayID: String] = [:]
    /// Names survive reconfigurations: an inactive display no longer has an NSScreen to ask.
    private var keyNameCache: [DisplayKey: String] = [:]

    public init() {
        refresh()
        CGDisplayRegisterReconfigurationCallback(managerReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(managerReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    public func refresh() {
        let active = Self.activeIDs()
        let activeSet = Set(active)
        let mainID = CGMainDisplayID()
        var result: [Display] = []
        for id in active {
            result.append(snapshot(id, isMain: id == mainID, isEnabled: true))
        }

        // Disabled displays vanish from every system display list (online included), so they are listed
        // from what we remember: this run's snapshots plus the toggle service's persisted entries.
        var listed = activeSet
        var inactive: [Display] = []
        func addInactive(_ base: Display) {
            guard !listed.contains(base.id) else { return }
            listed.insert(base.id)
            var d = base
            d.isMain = false
            d.isEnabled = false
            inactive.append(d)
        }
        disabled = disabled.filter { !activeSet.contains($0.key) }
        for (_, d) in disabled.sorted(by: { $0.key < $1.key }) { addInactive(d) }
        for entry in disabledProvider?() ?? [] where !activeSet.contains(entry.id) {
            // Reuse what we knew about it while it was active (name, mode) when possible.
            // Matched by id only: identical monitors share a key, so a key match could hand out another display's id.
            let previous = displays.first(where: { $0.id == entry.id })
            addInactive(previous ?? Display(
                id: entry.id, key: entry.key,
                name: entry.name ?? keyNameCache[entry.key] ?? "Display",
                isBuiltin: entry.isBuiltin ?? false, isMain: false, isEnabled: false, isVirtual: false, currentMode: nil
            ))
        }
        result.append(contentsOf: inactive.sorted { $0.id < $1.id })

        // Built-in first, then by main, then left-to-right.
        result.sort { a, b in
            if a.isBuiltin != b.isBuiltin { return a.isBuiltin }
            if a.isEnabled != b.isEnabled { return a.isEnabled }
            // Inactive ids have no bounds; tie-break on id so the order (and @Published) stays stable.
            let ax = CGDisplayBounds(a.id).minX, bx = CGDisplayBounds(b.id).minX
            return ax != bx ? ax < bx : a.id < b.id
        }
        if result != displays { displays = result }
    }

    /// Called by the toggle service right before it disables a display so it stays listed.
    public func markDisabled(_ id: CGDirectDisplayID) {
        if let d = displays.first(where: { $0.id == id }) {
            var copy = d
            copy.isEnabled = false
            disabled[id] = copy
        }
    }

    public func forgetDisabled(_ id: CGDirectDisplayID) {
        disabled.removeValue(forKey: id)
    }

    public var activeCount: Int { displays.filter(\.isEnabled).count }

    // MARK: - Private

    private func snapshot(_ id: CGDirectDisplayID, isMain: Bool, isEnabled: Bool) -> Display {
        Display(
            id: id,
            key: DisplayKey(id),
            name: name(for: id),
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isMain: isMain,
            isEnabled: isEnabled,
            isVirtual: Self.isLikelyVirtual(id),
            currentMode: CGDisplayCopyDisplayMode(id).map(DisplayModeOption.init(cgMode:))
        )
    }

    private func name(for id: CGDirectDisplayID) -> String {
        if let cached = nameCache[id] { return cached }
        let key = DisplayKey(id)
        let screenName = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName
        let n = screenName ?? keyNameCache[key] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
        nameCache[id] = n
        if screenName != nil { keyNameCache[key] = n }
        return n
    }

    private static func isLikelyVirtual(_ id: CGDirectDisplayID) -> Bool {
        // Virtual displays created via CGVirtualDisplay report no physical size.
        CGDisplayScreenSize(id) == .zero
    }

    private static func activeIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

extension DisplayModeOption {
    public init(cgMode m: CGDisplayMode) {
        self.init(
            width: m.width,
            height: m.height,
            pixelWidth: m.pixelWidth,
            pixelHeight: m.pixelHeight,
            refreshRate: m.refreshRate,
            ioModeID: m.ioDisplayModeID,
            isNative: (m.ioFlags & UInt32(kDisplayModeNativeFlag)) != 0
        )
    }
}
