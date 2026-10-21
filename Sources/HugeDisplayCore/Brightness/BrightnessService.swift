import CoreGraphics
import Foundation

/// Brightness for every display: built-in via DisplayServices, external via DDC/CI, gamma dimming otherwise.
/// The synchronous entry points (`backend(for:)`, `brightness(for:)`, `setBrightness`) never perform DDC I/O:
/// they only consult cached state and, when an external display is not resolved yet, answer provisionally
/// (`.none` / nil, writes are deferred) while an async probe runs on the DDC queue. `refreshBackend(for:)`
/// awaits that same probe.
@MainActor
public final class BrightnessService: BrightnessServicing {
    /// VCP code 0x10: luminance.
    public static let brightnessVCP: UInt8 = 0x10

    private struct Resolved {
        let key: DisplayKey
        let backend: BrightnessBackend
        /// Failed DDC probes are retried after this date instead of being remembered forever.
        let expires: Date?
    }

    private struct DDCValue {
        var current: UInt16
        var max: UInt16
    }

    private static let failedProbeRetry: TimeInterval = 30

    private let builtin = BuiltinBrightness()
    private let ddc = DDCController()
    private let dimmer = GammaDimmer()
    private var resolved: [CGDirectDisplayID: Resolved] = [:]
    private var ddcValues: [CGDirectDisplayID: DDCValue] = [:]
    /// In-flight DDC probes, so concurrent callers share one round trip.
    private var probes: [CGDirectDisplayID: Task<BrightnessBackend, Never>] = [:]
    /// Latest brightness requested while the backend was unresolved; applied when the probe finishes.
    private var deferred: [CGDirectDisplayID: Double] = [:]
    /// Bumped by `displaysChanged()` so probes started before a reconfiguration cannot cache stale results.
    private var epoch = 0

    public init() {}

    // MARK: - BrightnessServicing

    /// Cached state only, never blocks. An unresolved external display reports `.none` until the async probe
    /// it triggers completes; an expired failed probe keeps reporting `.software` while it is retried.
    public func backend(for display: CGDirectDisplayID) -> BrightnessBackend {
        if let cached = cachedBackend(display) { return cached }
        if let quick = quickBackend(display) { return remember(quick, for: display) }
        scheduleProbe(display)
        return staleBackend(display) ?? BrightnessBackend.none
    }

    public func brightness(for display: CGDirectDisplayID) -> Double? {
        switch backend(for: display) {
        case .builtin: builtin.brightness(display)
        case .ddc: ddcValues[display].map { DDCScaling.brightness(current: $0.current, max: $0.max) }
        case .software: dimmer.factor(for: display)
        case .none: nil
        }
    }

    /// Never performs DDC I/O on the caller's thread. If the backend is not resolved yet, the value is kept
    /// (newest wins) and applied as soon as the async probe resolves it.
    public func setBrightness(_ value: Double, for display: CGDirectDisplayID) throws {
        let clamped = min(max(value, 0), 1)
        if cachedBackend(display) == nil, quickBackend(display) == nil, staleBackend(display) == nil {
            deferred[display] = clamped
            scheduleProbe(display)
            return
        }
        try apply(clamped, backend: backend(for: display), to: display)
    }

    // MARK: - Async / lifecycle helpers

    /// Resolves the backend, running the DDC probe (if needed) on the DDC queue instead of blocking the caller.
    @discardableResult
    public func refreshBackend(for display: CGDirectDisplayID) async -> BrightnessBackend {
        if let cached = cachedBackend(display) { return cached }
        if let quick = quickBackend(display) { return remember(quick, for: display) }
        if let running = probes[display] { return await running.value }
        let startEpoch = epoch
        let task = Task { @MainActor [weak self] () -> BrightnessBackend in
            guard let self else { return .none }
            let probe = await self.ddc.readAsync(Self.brightnessVCP, display: display)
            let backend = self.finishProbe(probe, for: display, epoch: startEpoch)
            if self.epoch == startEpoch {
                self.probes[display] = nil
                if let value = self.deferred.removeValue(forKey: display) {
                    try? self.apply(value, backend: backend, to: display)
                }
            }
            return backend
        }
        probes[display] = task
        return await task.value
    }

    /// Re-reads the DDC brightness from the monitor (e.g. when the popover opens) off the main thread.
    /// Built-in and software backends just return their current value.
    public func refreshBrightness(for display: CGDirectDisplayID) async -> Double? {
        guard await refreshBackend(for: display) == .ddc else { return brightness(for: display) }
        if let value = await ddc.readAsync(Self.brightnessVCP, display: display) {
            ddcValues[display] = DDCValue(current: value.current, max: value.max)
        }
        return brightness(for: display)
    }

    /// Call after display reconfiguration: drops cached backends and DDC mappings (IDs can change) and
    /// re-applies software dimming, which macOS resets on reconfiguration and wake.
    public func displaysChanged() {
        epoch += 1
        resolved.removeAll()
        ddcValues.removeAll()
        probes.removeAll()
        ddc.invalidate()
        dimmer.reapply()
    }

    /// Re-pushes gamma dimming. Cheap and safe to call on every completed display reconfiguration, on wake
    /// and after a color profile is applied: it only touches CoreGraphics gamma tables, never DDC.
    /// Displays that are not software-dimmed are left alone.
    public func reapplySoftwareDimming() {
        dimmer.reapply()
    }

    /// Resets every display to its ColorSync profile. Call on quit.
    public func restoreSoftwareDimming() {
        dimmer.restoreAll()
    }

    // MARK: - Generic DDC (contrast, volume, ...)

    /// Blocking VCP read (serialized with pending writes). nil when the display has no DDC or the code is unsupported.
    public func readVCP(_ code: UInt8, display: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        ddc.read(code, display: display)
    }

    /// Non-blocking, coalesced VCP write: only the newest pending value per (display, code) is sent.
    public func writeVCP(_ code: UInt8, value: UInt16, display: CGDirectDisplayID) {
        ddc.write(code, value: value, display: display)
    }

    // MARK: - Private

    private func cachedBackend(_ display: CGDirectDisplayID) -> BrightnessBackend? {
        guard let entry = resolved[display], entry.key == DisplayKey(display) else { return nil }
        if let expires = entry.expires, expires <= Date() { return nil }
        return entry.backend
    }

    /// Everything that does not need a DDC round trip; nil means "probe DDC".
    private func quickBackend(_ display: CGDirectDisplayID) -> BrightnessBackend? {
        guard CGDisplayIsOnline(display) != 0 else { return BrightnessBackend.none }
        if builtin.canChange(display) { return .builtin }
        // Virtual displays and the built-in panel without DisplayServices have no DDC.
        if CGDisplayScreenSize(display) == .zero || CGDisplayIsBuiltin(display) != 0 { return .software }
        return nil
    }

    private func apply(_ value: Double, backend: BrightnessBackend, to display: CGDirectDisplayID) throws {
        switch backend {
        case .builtin:
            try builtin.setBrightness(value, display)
        case .ddc:
            guard var state = ddcValues[display] else { return }
            let raw = DDCScaling.raw(forBrightness: value, max: state.max)
            state.current = raw
            ddcValues[display] = state
            ddc.write(Self.brightnessVCP, value: raw, display: display)
        case .software:
            try dimmer.set(brightness: value, for: display)
        case .none:
            throw HugeDisplayError.unsupported(String(localized: "This display cannot be dimmed", bundle: .module))
        }
    }

    /// An expired (or otherwise outdated) entry for this very display, still usable as a provisional answer.
    private func staleBackend(_ display: CGDirectDisplayID) -> BrightnessBackend? {
        guard let entry = resolved[display], entry.key == DisplayKey(display) else { return nil }
        return entry.backend
    }

    private func scheduleProbe(_ display: CGDirectDisplayID) {
        guard probes[display] == nil else { return }
        Task { await refreshBackend(for: display) }
    }

    private func finishProbe(_ probe: (current: UInt16, max: UInt16)?, for display: CGDirectDisplayID, epoch probeEpoch: Int) -> BrightnessBackend {
        // A reconfiguration happened while probing: the result may belong to another display, do not cache it.
        guard probeEpoch == epoch else { return probe == nil ? .software : .ddc }
        if let probe {
            ddcValues[display] = DDCValue(current: probe.current, max: probe.max)
            return remember(.ddc, for: display)
        }
        return remember(.software, for: display, expiresIn: Self.failedProbeRetry)
    }

    @discardableResult
    private func remember(_ backend: BrightnessBackend, for display: CGDirectDisplayID, expiresIn: TimeInterval? = nil) -> BrightnessBackend {
        // Offline displays have no stable identity worth caching.
        guard backend != .none else { return backend }
        // Hardware control took over from gamma dimming: undo the gamma so the display is not dimmed twice.
        if backend != .software { dimmer.reset(display) }
        resolved[display] = Resolved(key: DisplayKey(display), backend: backend, expires: expiresIn.map { Date().addingTimeInterval($0) })
        return backend
    }
}
