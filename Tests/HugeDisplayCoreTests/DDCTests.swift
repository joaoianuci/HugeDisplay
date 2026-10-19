import XCTest
@testable import HugeDisplayCore

final class DDCTests: XCTestCase {
    // MARK: Packets

    func testGetVCPPacketAndChecksum() {
        // Confirmed on hardware: [0x82, 0x01, vcp, 0x6E ^ 0x82 ^ 0x01 ^ vcp]
        XCTAssertEqual(DDCPacket.getVCP(0x10), [0x82, 0x01, 0x10, 0x6E ^ 0x82 ^ 0x01 ^ 0x10])
        XCTAssertEqual(DDCPacket.getVCP(0x10).last, 0xFD)
        XCTAssertEqual(DDCPacket.getVCP(0x62).count, 4)
    }

    func testSetVCPPacketAndChecksum() {
        let p = DDCPacket.setVCP(0x10, value: 0x0140)
        XCTAssertEqual(Array(p.prefix(5)), [0x84, 0x03, 0x10, 0x01, 0x40])
        XCTAssertEqual(p[5], 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x01 ^ 0x40)
        XCTAssertEqual(DDCPacket.setVCP(0x10, value: 63), [0x84, 0x03, 0x10, 0x00, 0x3F, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x3F])
    }

    // MARK: Replies

    private func reply(code: UInt8 = 0x10, result: UInt8 = 0, max: UInt16, current: UInt16) -> [UInt8] {
        var r: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00, UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        r.append(r.reduce(0x50) { $0 ^ $1 })
        return r
    }

    func testParseReplyReadsMaxThenCurrent() {
        XCTAssertEqual(DDCPacket.parseReply(reply(max: 100, current: 63), expecting: 0x10), .value(current: 63, max: 100))
        XCTAssertEqual(DDCPacket.parseReply(reply(max: 0x0201, current: 0x0102)), .value(current: 0x0102, max: 0x0201))
    }

    func testParseReplyRejectsBadInput() {
        var bad = reply(max: 100, current: 63)
        bad[10] ^= 0xFF
        XCTAssertEqual(DDCPacket.parseReply(bad), .invalid)
        XCTAssertEqual(DDCPacket.parseReply([UInt8](repeating: 0, count: 11)), .invalid)
        XCTAssertEqual(DDCPacket.parseReply([0x6E, 0x88]), .invalid)
        XCTAssertEqual(DDCPacket.parseReply(reply(code: 0x12, max: 100, current: 1), expecting: 0x10), .invalid)
    }

    func testParseReplyUnsupported() {
        XCTAssertEqual(DDCPacket.parseReply(reply(code: 0xDC, result: 1, max: 0, current: 0), expecting: 0xDC), .unsupported)
    }

    // MARK: Scaling

    func testScaling() {
        XCTAssertEqual(DDCScaling.raw(forBrightness: 0.5, max: 100), 50)
        XCTAssertEqual(DDCScaling.raw(forBrightness: 1.7, max: 100), 100)
        XCTAssertEqual(DDCScaling.raw(forBrightness: -1, max: 100), 0)
        XCTAssertEqual(DDCScaling.raw(forBrightness: 0.5, max: 0), 50)
        XCTAssertEqual(DDCScaling.brightness(current: 63, max: 100), 0.63, accuracy: 1e-9)
        XCTAssertEqual(DDCScaling.brightness(current: 500, max: 100), 1)
    }

    func testGammaFactorFloor() {
        XCTAssertEqual(GammaDimmer.factor(forBrightness: 0), 0.1)
        XCTAssertEqual(GammaDimmer.factor(forBrightness: 0.5), 0.5)
        XCTAssertEqual(GammaDimmer.factor(forBrightness: 3), 1)
    }

    // MARK: Coalescing

    func testCoalescerKeepsOnlyLatestValue() {
        let c = LatestValueCoalescer<String, Int>()
        XCTAssertTrue(c.submit(1, for: "a"), "first submit must schedule a drain")
        XCTAssertFalse(c.submit(2, for: "a"))
        XCTAssertFalse(c.submit(3, for: "a"))
        XCTAssertEqual(c.take(for: "a"), 3)
        XCTAssertNil(c.take(for: "a"))
        XCTAssertTrue(c.submit(4, for: "a"), "after draining, the next submit schedules again")
    }

    func testCoalescerKeysAreIndependent() {
        let c = LatestValueCoalescer<String, Int>()
        XCTAssertTrue(c.submit(1, for: "a"))
        XCTAssertTrue(c.submit(2, for: "b"))
        XCTAssertEqual(c.take(for: "b"), 2)
        XCTAssertEqual(c.take(for: "a"), 1)
    }

    func testCoalescerSubmitDuringDrainIsNotLost() {
        let c = LatestValueCoalescer<String, Int>()
        XCTAssertTrue(c.submit(1, for: "a"))
        XCTAssertEqual(c.take(for: "a"), 1)
        XCTAssertFalse(c.submit(2, for: "a"), "drain still running, it will pick this up")
        XCTAssertEqual(c.take(for: "a"), 2)
        XCTAssertNil(c.take(for: "a"))
    }

    // MARK: EDID matching

    func testEDIDParse() {
        var edid = [UInt8](repeating: 0, count: 128)
        edid[1...6] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        edid[8] = 0x1E; edid[9] = 0x6D; edid[10] = 0x14; edid[11] = 0x77
        edid[12] = 0x01; edid[13] = 0x02; edid[14] = 0x03; edid[15] = 0x04
        XCTAssertEqual(EDIDIdentity(edid: edid), EDIDIdentity(vendor: 0x1E6D, product: 0x7714, serial: 0x04030201))
        edid[0] = 1
        XCTAssertNil(EDIDIdentity(edid: edid))
    }

    func testMatcherDirectMapping() {
        let d = EDIDIdentity(vendor: 1, product: 2, serial: 3)
        XCTAssertEqual(DDCMatcher.assign(displays: [d], services: [nil]), [0: 0])
    }

    func testMatcherByEDIDWithTwoDisplays() {
        let a = EDIDIdentity(vendor: 0x1E6D, product: 0x7714, serial: 0)
        let b = EDIDIdentity(vendor: 0x10AC, product: 0xA0C0, serial: 0)
        // Services listed in the opposite order of displays.
        XCTAssertEqual(DDCMatcher.assign(displays: [a, b], services: [b, a]), [0: 1, 1: 0])
    }

    func testMatcherRefusesIdenticalMonitorsWithoutSerials() {
        let a = EDIDIdentity(vendor: 1, product: 2, serial: 0)
        XCTAssertTrue(DDCMatcher.assign(displays: [a, a], services: [a, a]).isEmpty)
    }

    func testMatcherSerialBreaksTie() {
        let a = EDIDIdentity(vendor: 1, product: 2, serial: 111)
        let b = EDIDIdentity(vendor: 1, product: 2, serial: 222)
        XCTAssertEqual(DDCMatcher.assign(displays: [a, b], services: [b, a]), [0: 1, 1: 0])
    }

    func testMatcherSkipsUnreadableEDID() {
        let a = EDIDIdentity(vendor: 1, product: 2, serial: 0)
        let b = EDIDIdentity(vendor: 3, product: 4, serial: 0)
        XCTAssertEqual(DDCMatcher.assign(displays: [a, b], services: [nil, b]), [1: 1])
    }
}
