import CoreGraphics

// STUB — replaced by the Color module.
@MainActor
public final class ColorService: ColorServicing {
    public init() {}
    public func presets(for display: CGDirectDisplayID) -> [ColorPreset] { [] }
    public func currentPreset(for display: CGDirectDisplayID) -> ColorPreset? { nil }
    public func apply(_ preset: ColorPreset, to display: CGDirectDisplayID) throws {
        throw HugeDisplayError.unsupported("Color presets not implemented yet")
    }
}
