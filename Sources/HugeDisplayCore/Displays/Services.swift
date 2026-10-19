import CoreGraphics
import Foundation

// Module contracts. Each feature lives in its own folder and implements one of these,
// so features can be built and tested independently. All services are main-actor bound:
// display reconfiguration APIs are not thread-safe and the UI reads them directly.

public enum HugeDisplayError: Error, LocalizedError {
    case unsupported(String)
    case privateAPIUnavailable(String)
    case operationFailed(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s), .privateAPIUnavailable(let s), .operationFailed(let s), .refused(let s): s
        }
    }
}

@MainActor
public protocol ModeServicing: AnyObject {
    /// Modes usable for the desktop GUI, de-duplicated and sorted (largest first, then refresh rate desc).
    func modes(for display: CGDirectDisplayID) -> [DisplayModeOption]
    func currentMode(for display: CGDirectDisplayID) -> DisplayModeOption?
    func apply(_ mode: DisplayModeOption, to display: CGDirectDisplayID) throws
}

@MainActor
public protocol DisplayToggleServicing: AnyObject {
    var isAvailable: Bool { get }
    /// Displays HugeDisplay knows about, including ones it disabled (they disappear from the active list).
    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws
}

public enum BrightnessBackend: String, Sendable {
    case builtin      // DisplayServices (internal panel)
    case ddc          // DDC/CI over IOAVService (external)
    case software     // gamma-table dimming fallback
    case none
}

@MainActor
public protocol BrightnessServicing: AnyObject {
    func backend(for display: CGDirectDisplayID) -> BrightnessBackend
    /// 0...1, nil when unknown.
    func brightness(for display: CGDirectDisplayID) -> Double?
    func setBrightness(_ value: Double, for display: CGDirectDisplayID) throws
}

public struct ColorPreset: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
public protocol ColorServicing: AnyObject {
    func presets(for display: CGDirectDisplayID) -> [ColorPreset]
    func currentPreset(for display: CGDirectDisplayID) -> ColorPreset?
    func apply(_ preset: ColorPreset, to display: CGDirectDisplayID) throws
}

@MainActor
public protocol PIPServicing: AnyObject {
    var hasPermission: Bool { get }
    func requestPermission()
    func isShowing(source display: CGDirectDisplayID) -> Bool
    func show(source display: CGDirectDisplayID) async throws
    func close(source display: CGDirectDisplayID)
}
