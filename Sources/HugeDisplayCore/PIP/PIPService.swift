import CoreGraphics

// STUB — replaced by the PIP module.
@MainActor
public final class PIPService: PIPServicing {
    public init() {}
    public var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    public func requestPermission() { _ = CGRequestScreenCaptureAccess() }
    public func isShowing(source display: CGDirectDisplayID) -> Bool { false }
    public func show(source display: CGDirectDisplayID) async throws {
        throw HugeDisplayError.unsupported("PIP not implemented yet")
    }
    public func close(source display: CGDirectDisplayID) {}
}
