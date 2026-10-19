import Foundation
import IOKit

// DDC/CI over IOAVService (Apple Silicon external displays).
// Packet framing and timings are the ones confirmed on real hardware, see docs/research/brightness-color.md.

/// Pure DDC/CI packet building and reply parsing (no I/O, unit tested).
public enum DDCPacket {
    /// 7-bit I2C chip address of the DDC/CI endpoint.
    public static let chipAddress: UInt8 = 0x37
    /// Host "data address" byte that prefixes every message on the wire.
    public static let dataAddress: UInt8 = 0x51
    public static let getVCPOpcode: UInt8 = 0x01
    public static let setVCPOpcode: UInt8 = 0x03
    /// Get VCP Feature reply: 6E 88 02 result vcp type maxH maxL curH curL chk.
    public static let replyLength = 11

    public enum Reply: Equatable {
        case value(current: UInt16, max: UInt16)
        /// The monitor answered but does not implement this VCP code (result byte 1).
        case unsupported
        /// Bad checksum / wrong opcode / short or all-zero buffer: worth retrying.
        case invalid
    }

    static func checksum(seed: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// [0x82, 0x01, vcp, chk]. Single-byte payloads use seed 0x6E (chip << 1) only.
    public static func getVCP(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x80 | 2, getVCPOpcode, code]
        return body + [checksum(seed: chipAddress << 1, body)]
    }

    /// [0x84, 0x03, vcp, hi, lo, chk]. Multi-byte payloads also fold in the data address (0x6E ^ 0x51).
    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x80 | 4, setVCPOpcode, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(seed: (chipAddress << 1) ^ dataAddress, body)]
    }

    /// Bytes 6-7 = max, 8-9 = current, byte 10 = checksum (0x50 ^ bytes 0...9).
    public static func parseReply(_ reply: [UInt8], expecting code: UInt8? = nil) -> Reply {
        guard reply.count >= replyLength else { return .invalid }
        guard checksum(seed: 0x50, Array(reply[0..<10])) == reply[10] else { return .invalid }
        guard reply[2] == 0x02 else { return .invalid }
        if reply[3] == 0x01 { return .unsupported }
        guard reply[3] == 0x00 else { return .invalid }
        if let code, reply[4] != code { return .invalid }
        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return .value(current: current, max: maxValue)
    }
}

/// Conversions between the 0...1 slider range and raw VCP values.
public enum DDCScaling {
    public static let defaultMax: UInt16 = 100

    public static func raw(forBrightness value: Double, max: UInt16) -> UInt16 {
        let top = max == 0 ? defaultMax : max
        let clamped = Swift.min(Swift.max(value, 0), 1)
        return UInt16((clamped * Double(top)).rounded())
    }

    public static func brightness(current: UInt16, max: UInt16) -> Double {
        let top = max == 0 ? defaultMax : max
        return Swift.min(Swift.max(Double(current) / Double(top), 0), 1)
    }
}

/// Timings (microseconds) and retry policy. Defaults are the profile measured at ~47 ms/read, 0 failures.
struct DDCTiming {
    var writeSleep: UInt32 = 5_000
    var readSleep: UInt32 = 30_000
    var retrySleep: UInt32 = 20_000
    var attempts = 3
}

/// Resolved IOAVService entry points. Nil when the OS no longer exports them (feature degrades to software).
struct DDCSymbols {
    typealias CreateFn = @convention(c) (UnsafeRawPointer?, UInt32) -> UnsafeMutableRawPointer?
    typealias I2CFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    let create: CreateFn
    let read: I2CFn
    let write: I2CFn

    static let shared: DDCSymbols? = {
        let path = PrivateSymbol.ioKit
        guard let create = PrivateSymbol.load("IOAVServiceCreateWithService", from: path, as: CreateFn.self),
              let read = PrivateSymbol.load("IOAVServiceReadI2C", from: path, as: I2CFn.self),
              let write = PrivateSymbol.load("IOAVServiceWriteI2C", from: path, as: I2CFn.self)
        else { return nil }
        return DDCSymbols(create: create, read: read, write: write)
    }()
}

/// One monitor's I2C channel. Blocking and NOT thread-safe: only ever used from DDCController's serial queue.
final class DDCBus: @unchecked Sendable {
    private let symbols: DDCSymbols
    private let service: UnsafeMutableRawPointer
    var timing = DDCTiming()

    /// - Parameter ioService: a DCPAVServiceProxy registry entry (the caller keeps ownership of it).
    init?(ioService: io_service_t) {
        guard let symbols = DDCSymbols.shared, let svc = symbols.create(nil, ioService) else { return nil }
        self.symbols = symbols
        self.service = svc
    }

    deinit {
        Unmanaged<CFTypeRef>.fromOpaque(service).release()
    }

    func readVCP(_ code: UInt8) -> (current: UInt16, max: UInt16)? {
        var packet = DDCPacket.getVCP(code)
        for attempt in 0..<timing.attempts {
            if attempt > 0 { usleep(timing.retrySleep) }
            usleep(timing.writeSleep)
            guard i2cWrite(&packet) == 0 else { continue }
            usleep(timing.readSleep)
            var reply = [UInt8](repeating: 0, count: DDCPacket.replyLength)
            guard i2cRead(chip: UInt32(DDCPacket.chipAddress), &reply) == 0 else { continue }
            switch DDCPacket.parseReply(reply, expecting: code) {
            case .value(let current, let max): return (current, max)
            case .unsupported: return nil
            case .invalid: continue
            }
        }
        return nil
    }

    @discardableResult
    func writeVCP(_ code: UInt8, value: UInt16) -> Bool {
        var packet = DDCPacket.setVCP(code, value: value)
        for attempt in 0..<timing.attempts {
            if attempt > 0 { usleep(timing.retrySleep) }
            usleep(timing.writeSleep)
            if i2cWrite(&packet) == 0 { return true }
        }
        return false
    }

    /// 128-byte base EDID straight from the monitor (used to map this bus to a CGDirectDisplayID).
    func readEDID() -> [UInt8]? {
        for attempt in 0..<2 {
            if attempt > 0 { usleep(timing.retrySleep) }
            var edid = [UInt8](repeating: 0, count: 128)
            guard i2cRead(chip: 0x50, &edid) == 0 else { continue }
            if EDIDIdentity(edid: edid) != nil { return edid }
        }
        return nil
    }

    private func i2cWrite(_ packet: inout [UInt8]) -> Int32 {
        packet.withUnsafeMutableBytes {
            symbols.write(service, UInt32(DDCPacket.chipAddress), UInt32(DDCPacket.dataAddress), $0.baseAddress!, UInt32($0.count))
        }
    }

    private func i2cRead(chip: UInt32, _ buffer: inout [UInt8]) -> Int32 {
        buffer.withUnsafeMutableBytes {
            symbols.read(service, chip, 0, $0.baseAddress!, UInt32($0.count))
        }
    }
}

/// Keeps only the newest pending value per key, so a slider drag never builds a queue of stale writes.
/// Usage: `if submit(v, for: k) { schedule { while let v = take(for: k) { write(v) } } }`.
final class LatestValueCoalescer<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Key: Value] = [:]
    private var scheduled: Set<Key> = []

    /// Stores the value (replacing any older pending one). Returns true when the caller must start a drain.
    func submit(_ value: Value, for key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending[key] = value
        return scheduled.insert(key).inserted
    }

    /// Next value to write, or nil when drained (which also ends the "scheduled" state atomically).
    func take(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        if let value = pending.removeValue(forKey: key) { return value }
        scheduled.remove(key)
        return nil
    }
}
