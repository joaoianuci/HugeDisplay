import CoreGraphics

// STUB — replaced by the Toggle module.
@MainActor
public final class DisplayToggleService: DisplayToggleServicing {
    private unowned let manager: DisplayManager
    public init(manager: DisplayManager) { self.manager = manager }
    public var isAvailable: Bool { false }
    public func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws {
        throw HugeDisplayError.unsupported("Display toggle not implemented yet")
    }
}
