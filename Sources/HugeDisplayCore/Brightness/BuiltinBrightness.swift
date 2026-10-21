import CoreGraphics
import Foundation

/// Internal-panel brightness through the private DisplayServices framework (resolved with dlsym).
/// Never calls DisplayServicesAmbientLightCompensationEnabled: it segfaults with the guessed signature.
struct BuiltinBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private typealias CanFn = @convention(c) (UInt32) -> Bool

    private let get: GetFn?
    private let set: SetFn?
    private let can: CanFn?

    init() {
        let path = PrivateSymbol.displayServices
        get = PrivateSymbol.load("DisplayServicesGetBrightness", from: path, as: GetFn.self)
        set = PrivateSymbol.load("DisplayServicesSetBrightness", from: path, as: SetFn.self)
        can = PrivateSymbol.load("DisplayServicesCanChangeBrightness", from: path, as: CanFn.self)
    }

    /// True only when all three symbols exist and the system says this display is adjustable.
    func canChange(_ id: CGDirectDisplayID) -> Bool {
        guard get != nil, set != nil, let can else { return false }
        return can(id)
    }

    func brightness(_ id: CGDirectDisplayID) -> Double? {
        guard let get else { return nil }
        var value: Float = 0
        guard get(id, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    func setBrightness(_ value: Double, _ id: CGDirectDisplayID) throws {
        guard let set else { throw HugeDisplayError.privateAPIUnavailable(String(localized: "DisplayServices brightness is unavailable", bundle: .module)) }
        let rc = set(id, Float(min(max(value, 0), 1)))
        guard rc == 0 else { throw HugeDisplayError.operationFailed(String(localized: "DisplayServicesSetBrightness failed (\(Int(rc)))", bundle: .module)) }
    }
}
