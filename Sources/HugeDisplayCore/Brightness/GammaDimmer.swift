import CoreGraphics
import Foundation

/// Software fallback: scales the display's gamma transfer curve. Process-owned, so it must be
/// restored on quit (CGDisplayRestoreColorSyncSettings) and reapplied after reconfiguration/wake.
final class GammaDimmer {
    /// Never go fully black: a 0 slider would make the screen unrecoverable without the app.
    static let floor: Float = 0.1

    private var factors: [CGDirectDisplayID: Float] = [:]

    static func factor(forBrightness value: Double) -> Float {
        min(max(Float(value), floor), 1)
    }

    func factor(for id: CGDirectDisplayID) -> Double {
        Double(factors[id] ?? 1)
    }

    func set(brightness value: Double, for id: CGDirectDisplayID) throws {
        let f = Self.factor(forBrightness: value)
        try apply(f, to: id)
        factors[id] = f
    }

    /// Re-pushes the stored factors (call after display reconfiguration or wake).
    func reapply() {
        for (id, f) in factors where f < 1 {
            try? apply(f, to: id)
        }
    }

    func restoreAll() {
        guard !factors.isEmpty else { return }
        CGDisplayRestoreColorSyncSettings()
        factors.removeAll()
    }

    private func apply(_ f: Float, to id: CGDirectDisplayID) throws {
        let err = CGSetDisplayTransferByFormula(id, 0, f, 1, 0, f, 1, 0, f, 1)
        guard err == .success else { throw HugeDisplayError.operationFailed("Gamma dimming failed (\(err.rawValue))") }
    }
}
