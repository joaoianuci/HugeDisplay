import XCTest
@testable import HugeDisplayCore

final class DisplayModelTests: XCTestCase {
    func testHiDPIFlag() {
        let m = DisplayModeOption(width: 2560, height: 1080, pixelWidth: 5120, pixelHeight: 2160, refreshRate: 75, ioModeID: 1, isNative: false)
        XCTAssertTrue(m.isHiDPI)
    }

    func testDisplayKeyDescription() {
        XCTAssertEqual(DisplayKey(vendor: 1, model: 2, serial: 3).description, "1-2-3")
    }
}
