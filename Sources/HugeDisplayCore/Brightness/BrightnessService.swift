import CoreGraphics

// STUB — replaced by the Brightness module.
@MainActor
public final class BrightnessService: BrightnessServicing {
    public init() {}
    public func backend(for display: CGDirectDisplayID) -> BrightnessBackend { .none }
    public func brightness(for display: CGDirectDisplayID) -> Double? { nil }
    public func setBrightness(_ value: Double, for display: CGDirectDisplayID) throws {
        throw HugeDisplayError.unsupported("Brightness not implemented yet")
    }
}
