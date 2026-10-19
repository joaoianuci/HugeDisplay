import CoreGraphics
import Foundation

/// Stable identity for a physical display across reconnects and enable/disable.
/// CGDirectDisplayID can change between sessions, so persisted settings key off this.
public struct DisplayKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    public init(_ id: CGDirectDisplayID) {
        self.init(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }

    public var description: String { "\(vendor)-\(model)-\(serial)" }
}

/// One selectable display mode (resolution + refresh rate).
public struct DisplayModeOption: Hashable, Identifiable, Sendable {
    /// Logical ("looks like") size in points.
    public let width: Int
    public let height: Int
    /// Backing pixel size.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let ioModeID: Int32
    public let isNative: Bool

    public var isHiDPI: Bool { pixelWidth > width }
    public var id: String { "\(ioModeID)-\(width)x\(height)@\(refreshRate)-\(pixelWidth)" }

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, ioModeID: Int32, isNative: Bool) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioModeID = ioModeID
        self.isNative = isNative
    }
}

/// Snapshot of a display as seen by HugeDisplay. Value type; DisplayManager publishes fresh arrays.
public struct Display: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let key: DisplayKey
    public var name: String
    public var isBuiltin: Bool
    public var isMain: Bool
    /// false when HugeDisplay (or the system) has disabled it but it is still online/known.
    public var isEnabled: Bool
    public var isVirtual: Bool
    public var currentMode: DisplayModeOption?

    public init(id: CGDirectDisplayID, key: DisplayKey, name: String, isBuiltin: Bool, isMain: Bool, isEnabled: Bool, isVirtual: Bool, currentMode: DisplayModeOption?) {
        self.id = id
        self.key = key
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.isEnabled = isEnabled
        self.isVirtual = isVirtual
        self.currentMode = currentMode
    }
}
