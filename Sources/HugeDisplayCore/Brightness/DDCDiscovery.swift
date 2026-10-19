import CoreGraphics
import Foundation
import IOKit

/// Vendor/product/serial as found in the first bytes of an EDID block and in CGDisplay*Number.
struct EDIDIdentity: Equatable {
    var vendor: UInt32
    var product: UInt32
    var serial: UInt32

    init(vendor: UInt32, product: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
    }

    init?(edid: [UInt8]) {
        guard edid.count >= 16, edid[0] == 0x00, edid[7] == 0x00, edid[1...6].allSatisfy({ $0 == 0xFF }) else { return nil }
        vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
        product = UInt32(edid[11]) << 8 | UInt32(edid[10])
        serial = UInt32(edid[15]) << 24 | UInt32(edid[14]) << 16 | UInt32(edid[13]) << 8 | UInt32(edid[12])
    }

    init(display id: CGDirectDisplayID) {
        self.init(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }
}

/// Pure display <-> AV service matching (EDID scoring, a simplified take on MonitorControl's approach).
enum DDCMatcher {
    static let minimumScore = 4

    /// Vendor and product must agree (2 each); a known serial adds 1, a conflicting serial disqualifies.
    static func score(display: EDIDIdentity, service: EDIDIdentity) -> Int {
        var s = 0
        if display.vendor == service.vendor { s += 2 }
        if display.product == service.product { s += 2 }
        if display.serial != 0, service.serial != 0 {
            if display.serial == service.serial { s += 1 } else { s -= 5 }
        }
        return s
    }

    /// Returns display index -> service index. One display + one service maps directly; otherwise
    /// ambiguous matches (identical monitors) are left unmapped rather than risking control of the wrong screen.
    static func assign(displays: [EDIDIdentity], services: [EDIDIdentity?]) -> [Int: Int] {
        if displays.count == 1, services.count == 1 { return [0: 0] }
        var claims: [Int: Int] = [:] // service index -> number of displays that want it
        var choice: [Int: Int] = [:]
        for (d, display) in displays.enumerated() {
            let scores = services.map { $0.map { score(display: display, service: $0) } ?? Int.min }
            guard let best = scores.max(), best >= minimumScore, scores.filter({ $0 == best }).count == 1,
                  let s = scores.firstIndex(of: best) else { continue }
            choice[d] = s
            claims[s, default: 0] += 1
        }
        return choice.filter { claims[$0.value] == 1 }
    }
}

enum DDCDiscovery {
    /// All external AV services, each wrapped in a bus. Built-in ("Embedded") services are skipped.
    static func externalBuses() -> [DDCBus] {
        guard DDCSymbols.shared != nil else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var buses: [DDCBus] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External", let bus = DDCBus(ioService: entry) else { continue }
            buses.append(bus)
        }
        return buses
    }

    /// Online, physical, non-built-in displays: the ones that can be behind an external AV service.
    static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayScreenSize($0) != .zero }
    }

    /// Display ID -> bus for every external display that could be mapped.
    static func buses(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCBus] {
        let buses = externalBuses()
        guard !buses.isEmpty, !displays.isEmpty else { return [:] }
        let identities: [EDIDIdentity?] = (displays.count == 1 && buses.count == 1)
            ? [nil] // direct mapping, no EDID read needed
            : buses.map { $0.readEDID().flatMap { EDIDIdentity(edid: $0) } }
        let assignment = DDCMatcher.assign(displays: displays.map { EDIDIdentity(display: $0) }, services: identities)
        var result: [CGDirectDisplayID: DDCBus] = [:]
        for (d, s) in assignment { result[displays[d]] = buses[s] }
        return result
    }
}
