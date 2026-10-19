import AppKit
import Combine
import CoreGraphics

/// Source of truth for the display list. Event-driven: refreshes only on CoreGraphics
/// reconfiguration callbacks (no polling), which keeps idle CPU at ~0.
@MainActor
public final class DisplayManager: ObservableObject {
    @Published public private(set) var displays: [Display] = []

    /// Displays HugeDisplay disabled; kept so they stay listed (and can be re-enabled) while inactive.
    private var disabled: [CGDirectDisplayID: Display] = [:]
    private var nameCache: [CGDirectDisplayID: String] = [:]
    private var callbackRegistered = false

    public init() {
        refresh()
        registerReconfigurationCallback()
    }

    public func refresh() {
        let active = Self.activeIDs()
        let mainID = CGMainDisplayID()
        var result: [Display] = []
        for id in active {
            disabled.removeValue(forKey: id)
            result.append(snapshot(id, isMain: id == mainID, isEnabled: true))
        }
        for (_, var d) in disabled.sorted(by: { $0.key < $1.key }) {
            d.isMain = false
            d.isEnabled = false
            result.append(d)
        }
        // Built-in first, then by main, then left-to-right.
        result.sort { a, b in
            if a.isBuiltin != b.isBuiltin { return a.isBuiltin }
            if a.isEnabled != b.isEnabled { return a.isEnabled }
            return CGDisplayBounds(a.id).minX < CGDisplayBounds(b.id).minX
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
        let screenName = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName
        let n = screenName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
        nameCache[id] = n
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

    private func registerReconfigurationCallback() {
        guard !callbackRegistered else { return }
        callbackRegistered = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            // Ignore the "begin" phase; refresh once the change has landed.
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            let manager = Unmanaged<DisplayManager>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    manager.nameCache.removeAll()
                    manager.refresh()
                }
            }
        }, ctx)
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
