import CoreGraphics
import Foundation

/// Owns every DDC transaction. All I2C traffic runs on one dedicated serial queue (the calls block on
/// usleep + DCP round trips), writes are coalesced so only the newest pending value per (display, VCP) is sent.
final class DDCController: @unchecked Sendable {
    struct WriteKey: Hashable {
        let display: CGDirectDisplayID
        let code: UInt8
    }

    private let queue = DispatchQueue(label: "app.hugedisplay.ddc", qos: .userInitiated)
    private let coalescer = LatestValueCoalescer<WriteKey, UInt16>()

    // Confined to `queue`.
    private var buses: [CGDirectDisplayID: DDCBus] = [:]
    private var discovered: [CGDirectDisplayID: DisplayKey] = [:]

    /// Forget the display -> bus mapping (call after display reconfiguration).
    func invalidate() {
        queue.async { [self] in
            buses.removeAll()
            discovered.removeAll()
        }
    }

    /// Blocking read, serialized with pending writes. Do not call from latency-sensitive paths.
    func read(_ code: UInt8, display: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        queue.sync { bus(for: display)?.readVCP(code) }
    }

    func readAsync(_ code: UInt8, display: CGDirectDisplayID) async -> (current: UInt16, max: UInt16)? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: bus(for: display)?.readVCP(code))
            }
        }
    }

    /// Fire-and-forget. A newer value for the same (display, code) replaces one that has not been sent yet.
    func write(_ code: UInt8, value: UInt16, display: CGDirectDisplayID) {
        let key = WriteKey(display: display, code: code)
        guard coalescer.submit(value, for: key) else { return }
        queue.async { [self] in
            while let next = coalescer.take(for: key) {
                bus(for: display)?.writeVCP(code, value: next)
            }
        }
    }

    // MARK: - Private (queue only)

    private func bus(for id: CGDirectDisplayID) -> DDCBus? {
        let key = DisplayKey(id)
        if discovered[id] == key { return buses[id] }
        let displays = DDCDiscovery.externalDisplayIDs()
        buses = DDCDiscovery.buses(for: displays)
        discovered = Dictionary(uniqueKeysWithValues: displays.map { ($0, DisplayKey($0)) })
        return buses[id]
    }
}
