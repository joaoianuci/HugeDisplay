import CoreGraphics
import Foundation

/// Lists and applies display modes (resolution + refresh rate) using public CoreGraphics APIs only.
@MainActor
public final class ModeService: ModeServicing {
    /// CGDisplayMode objects by display, keyed by DisplayModeOption.id, so apply() hands CoreGraphics
    /// the exact object it enumerated. Rebuilt on every modes(for:) call (enumeration is ~0.1 ms).
    private var cache: [CGDirectDisplayID: [String: CGDisplayMode]] = [:]

    /// Seconds the user has to confirm a new mode before it reverts.
    public static let confirmationTimeout: TimeInterval = 15

    /// Displays awaiting confirmation, mapped to the mode to restore. Observe via `onPendingChange`.
    public private(set) var pendingConfirmation: [CGDirectDisplayID: DisplayModeOption] = [:]
    public var onPendingChange: (() -> Void)?
    private var revertItems: [CGDirectDisplayID: DispatchWorkItem] = [:]

    public init() {}

    // MARK: - ModeServicing

    public func modes(for display: CGDirectDisplayID) -> [DisplayModeOption] {
        // The option is required to see all refresh-rate variants of the same logical size.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let raw = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []

        var byID: [String: CGDisplayMode] = [:]
        var candidates: [DisplayModeOption] = []
        for m in raw where m.isUsableForDesktopGUI() {
            let option = DisplayModeOption(cgMode: m)
            if byID.updateValue(m, forKey: option.id) == nil { candidates.append(option) }
        }

        let result = Self.normalize(candidates)
        let keptIDs = Set(result.map(\.id))
        cache[display] = byID.filter { keptIDs.contains($0.key) }
        return result
    }

    /// The active mode, mapped onto the de-duplicated list entry when there is one, so it compares equal
    /// to what the UI shows; falls back to the raw mode (e.g. when its ioModeID was a dropped duplicate).
    public func currentMode(for display: CGDirectDisplayID) -> DisplayModeOption? {
        guard let cg = CGDisplayCopyDisplayMode(display) else { return nil }
        let raw = DisplayModeOption(cgMode: cg)
        return modes(for: display).first { Self.signature($0) == Self.signature(raw) } ?? raw
    }

    /// Applies for the session only and starts a 15 s confirmation window: call `confirm(_:)` to make it
    /// permanent, or `revert(_:)` (also fired automatically on timeout) to restore the previous mode.
    public func apply(_ mode: DisplayModeOption, to display: CGDirectDisplayID) throws {
        let previous = pendingConfirmation[display] ?? currentMode(for: display)
        try configure(mode, on: display, option: .forSession)
        if let previous, Self.signature(previous) != Self.signature(mode) {
            pendingConfirmation[display] = previous
            scheduleRevert(for: display)
        } else {
            // Nothing to go back to (or re-applied the same mode): no confirmation needed.
            clearPending(display)
        }
        onPendingChange?()
    }

    /// Keeps the current (session) mode by re-applying it permanently.
    public func confirm(_ display: CGDirectDisplayID) {
        guard pendingConfirmation[display] != nil else { return }
        if let current = currentMode(for: display) {
            do { try configure(current, on: display, option: .permanently) } catch { /* stays session-only */ }
        }
        clearPending(display)
        onPendingChange?()
    }

    /// Restores the mode that was active before the pending `apply`.
    public func revert(_ display: CGDirectDisplayID) {
        guard let previous = pendingConfirmation[display] else { return }
        clearPending(display)
        do { try configure(previous, on: display, option: .forSession) } catch { /* display gone: nothing to restore */ }
        onPendingChange?()
    }

    private func scheduleRevert(for display: CGDirectDisplayID) {
        revertItems[display]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.revert(display) }
        }
        revertItems[display] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationTimeout, execute: item)
    }

    private func clearPending(_ display: CGDirectDisplayID) {
        pendingConfirmation[display] = nil
        revertItems.removeValue(forKey: display)?.cancel()
    }

    private func configure(_ mode: DisplayModeOption, on display: CGDirectDisplayID, option: CGConfigureOption) throws {
        var cgMode = cache[display]?[mode.id]
        if cgMode == nil {
            _ = modes(for: display)
            cgMode = cache[display]?[mode.id]
        }
        guard let cgMode else {
            throw HugeDisplayError.operationFailed("Mode \(mode.width)x\(mode.height) is no longer available for this display")
        }

        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let config else {
            throw HugeDisplayError.operationFailed("Could not begin display configuration (CGError \(err.rawValue))")
        }
        err = CGConfigureDisplayWithDisplayMode(config, display, cgMode, nil)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw HugeDisplayError.operationFailed("Could not configure display mode (CGError \(err.rawValue))")
        }
        // CGCompleteDisplayConfiguration releases the config itself, success or not: never cancel after it.
        err = CGCompleteDisplayConfiguration(config, option)
        guard err == .success else {
            throw HugeDisplayError.operationFailed("Could not apply display mode (CGError \(err.rawValue))")
        }
    }

    // MARK: - UI helpers

    /// One entry per logical size for a resolution picker, largest first.
    public func resolutions(for display: CGDirectDisplayID) -> [DisplayModeOption] {
        Self.uniqueResolutions(modes(for: display), current: CGDisplayCopyDisplayMode(display).map(DisplayModeOption.init(cgMode:)))
    }

    /// Refresh rates available at a logical size / HiDPI variant, highest first.
    public func refreshRates(for display: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool) -> [Double] {
        Self.refreshRates(in: modes(for: display), width: width, height: height, hiDPI: hiDPI)
    }

    /// The mode at a logical size closest to the requested HiDPI-ness and refresh rate, for combining
    /// a resolution picker with a refresh-rate picker.
    public func mode(for display: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool, refreshRate: Double) -> DisplayModeOption? {
        Self.bestMode(in: modes(for: display), width: width, height: height, hiDPI: hiDPI, refreshRate: refreshRate)
    }

    // MARK: - Pure logic (unit tested)

    private struct Signature: Hashable {
        let width, height, pixelWidth, pixelHeight: Int
        let refreshCentiHz: Int
    }

    private nonisolated static func signature(_ m: DisplayModeOption) -> Signature {
        Signature(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                  refreshCentiHz: Int((m.refreshRate * 100).rounded()))
    }

    /// De-duplicates by (size, pixel size, refresh), keeping one ioModeID (native preferred, else the lowest,
    /// so the choice is deterministic), then sorts: largest logical size first, HiDPI before LoDPI, refresh descending.
    nonisolated static func normalize(_ options: [DisplayModeOption]) -> [DisplayModeOption] {
        var kept: [Signature: DisplayModeOption] = [:]
        for o in options {
            let key = signature(o)
            if let existing = kept[key], !prefer(o, over: existing) { continue }
            kept[key] = o
        }
        return kept.values.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            if a.pixelWidth != b.pixelWidth { return a.pixelWidth > b.pixelWidth }
            return a.ioModeID < b.ioModeID
        }
    }

    private nonisolated static func prefer(_ a: DisplayModeOption, over b: DisplayModeOption) -> Bool {
        if a.isNative != b.isNative { return a.isNative }
        return a.ioModeID < b.ioModeID
    }

    /// Picks one mode per logical size from a sorted list. Within a size it favours the current HiDPI-ness,
    /// then the current refresh rate, then the highest refresh rate. Keeps the input order of sizes.
    nonisolated static func uniqueResolutions(_ sorted: [DisplayModeOption], current: DisplayModeOption?) -> [DisplayModeOption] {
        var order: [[Int]] = []
        var best: [[Int]: DisplayModeOption] = [:]
        for m in sorted {
            let size = [m.width, m.height]
            guard let existing = best[size] else {
                order.append(size)
                best[size] = m
                continue
            }
            if isBetter(m, than: existing, hiDPI: current?.isHiDPI, refreshRate: current?.refreshRate) { best[size] = m }
        }
        return order.compactMap { best[$0] }
    }

    nonisolated static func refreshRates(in sorted: [DisplayModeOption], width: Int, height: Int, hiDPI: Bool) -> [Double] {
        var rates: [Double] = []
        for m in sorted where m.width == width && m.height == height && m.isHiDPI == hiDPI {
            if !rates.contains(where: { abs($0 - m.refreshRate) < 0.01 }) { rates.append(m.refreshRate) }
        }
        return rates.sorted(by: >)
    }

    nonisolated static func bestMode(in sorted: [DisplayModeOption], width: Int, height: Int, hiDPI: Bool, refreshRate: Double) -> DisplayModeOption? {
        var best: DisplayModeOption?
        for m in sorted where m.width == width && m.height == height {
            if let b = best, !isBetter(m, than: b, hiDPI: hiDPI, refreshRate: refreshRate) { continue }
            best = m
        }
        return best
    }

    /// Ranking used by both helpers: matching HiDPI-ness, then closest refresh rate (highest when none given).
    private nonisolated static func isBetter(_ a: DisplayModeOption, than b: DisplayModeOption, hiDPI: Bool?, refreshRate: Double?) -> Bool {
        if let hiDPI, (a.isHiDPI == hiDPI) != (b.isHiDPI == hiDPI) { return a.isHiDPI == hiDPI }
        if let refreshRate {
            let da = abs(a.refreshRate - refreshRate), db = abs(b.refreshRate - refreshRate)
            if abs(da - db) > 0.01 { return da < db }
        }
        return a.refreshRate > b.refreshRate
    }
}
