import XCTest
@testable import HugeDisplayCore

final class ModeServiceTests: XCTestCase {
    private func mode(_ w: Int, _ h: Int, hiDPI: Bool = false, hz: Double = 60, id: Int32 = 1, native: Bool = false) -> DisplayModeOption {
        DisplayModeOption(width: w, height: h, pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h, refreshRate: hz, ioModeID: id, isNative: native)
    }

    func testDedupeKeepsOneModePerSignature() {
        let out = ModeService.normalize([
            mode(2560, 1080, hz: 75, id: 9),
            mode(2560, 1080, hz: 75, id: 4),
            mode(2560, 1080, hz: 60, id: 5),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first?.ioModeID, 4, "lowest ioModeID kept deterministically")
    }

    func testDedupePrefersNative() {
        let out = ModeService.normalize([mode(2560, 1080, id: 2), mode(2560, 1080, id: 7, native: true)])
        XCTAssertEqual(out.map(\.ioModeID), [7])
    }

    func testHiDPIAndLoDPIAreDistinct() {
        let out = ModeService.normalize([mode(1280, 540), mode(1280, 540, hiDPI: true, id: 2)])
        XCTAssertEqual(out.count, 2)
    }

    func testSortOrder() {
        let out = ModeService.normalize([
            mode(1280, 720, hz: 60, id: 1),
            mode(2560, 1080, hz: 60, id: 2),
            mode(2560, 1080, hiDPI: true, hz: 50, id: 3),
            mode(2560, 1080, hz: 75, id: 4),
            mode(2560, 1080, hiDPI: true, hz: 75, id: 5),
            mode(1920, 1080, hz: 60, id: 6),
        ])
        XCTAssertEqual(out.map(\.ioModeID), [5, 3, 4, 2, 6, 1])
    }

    func testRefreshRatesFilterAndSort() {
        let sorted = ModeService.normalize([
            mode(2560, 1080, hz: 50, id: 1), mode(2560, 1080, hz: 75, id: 2), mode(2560, 1080, hz: 60, id: 3),
            mode(2560, 1080, hiDPI: true, hz: 75, id: 4), mode(1920, 1080, hz: 144, id: 5),
        ])
        XCTAssertEqual(ModeService.refreshRates(in: sorted, width: 2560, height: 1080, hiDPI: false), [75, 60, 50])
        XCTAssertEqual(ModeService.refreshRates(in: sorted, width: 2560, height: 1080, hiDPI: true), [75])
        XCTAssertEqual(ModeService.refreshRates(in: sorted, width: 800, height: 600, hiDPI: false), [])
    }

    func testUniqueResolutionsPrefersCurrentVariant() {
        let sorted = ModeService.normalize([
            mode(2560, 1080, hiDPI: true, hz: 75, id: 1), mode(2560, 1080, hz: 75, id: 2), mode(2560, 1080, hz: 60, id: 3),
            mode(1920, 1080, hz: 75, id: 4), mode(1920, 1080, hz: 60, id: 5),
        ])
        let current = mode(2560, 1080, hz: 60, id: 3)
        let out = ModeService.uniqueResolutions(sorted, current: current)
        XCTAssertEqual(out.map(\.ioModeID), [3, 5], "LoDPI + current 60 Hz preferred; sizes stay largest first")

        let hi = ModeService.uniqueResolutions(sorted, current: mode(2560, 1080, hiDPI: true, hz: 75, id: 1))
        XCTAssertEqual(hi.map(\.ioModeID), [1, 4], "HiDPI preferred where it exists, else fall back to LoDPI at 75 Hz")

        XCTAssertEqual(ModeService.uniqueResolutions(sorted, current: nil).map(\.ioModeID), [1, 4], "no current: highest refresh")
    }

    func testBestModeClosestRefresh() {
        let sorted = ModeService.normalize([
            mode(2560, 1080, hz: 75, id: 1), mode(2560, 1080, hz: 50, id: 2), mode(2560, 1080, hiDPI: true, hz: 60, id: 3),
        ])
        XCTAssertEqual(ModeService.bestMode(in: sorted, width: 2560, height: 1080, hiDPI: false, refreshRate: 70)?.ioModeID, 1)
        XCTAssertEqual(ModeService.bestMode(in: sorted, width: 2560, height: 1080, hiDPI: true, refreshRate: 120)?.ioModeID, 3)
        XCTAssertNil(ModeService.bestMode(in: sorted, width: 640, height: 480, hiDPI: false, refreshRate: 60))
    }
}
