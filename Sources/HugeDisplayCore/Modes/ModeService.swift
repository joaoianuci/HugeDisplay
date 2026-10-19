import CoreGraphics

// STUB — replaced by the Modes module.
@MainActor
public final class ModeService: ModeServicing {
    public init() {}
    public func modes(for display: CGDirectDisplayID) -> [DisplayModeOption] { [] }
    public func currentMode(for display: CGDirectDisplayID) -> DisplayModeOption? {
        CGDisplayCopyDisplayMode(display).map(DisplayModeOption.init(cgMode:))
    }
    public func apply(_ mode: DisplayModeOption, to display: CGDirectDisplayID) throws {
        throw HugeDisplayError.unsupported("Mode switching not implemented yet")
    }
}
