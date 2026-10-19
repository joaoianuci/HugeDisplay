import CoreGraphics
import XCTest
@testable import HugeDisplayCore

final class ColorServiceTests: XCTestCase {
    typealias E = ColorService.ProfileEntry

    func testFactoryFirstThenAlphabetical() {
        let out = ColorService.sortedAndDeduped([
            E(path: "/b", name: "sRGB", isFactory: false),
            E(path: "/a", name: "Adobe RGB", isFactory: false),
            E(path: "/f", name: "Zed Panel", isFactory: true),
        ])
        XCTAssertEqual(out.map(\.name), ["Zed Panel", "Adobe RGB", "sRGB"])
    }

    func testDedupeByNameKeepsFactory() {
        let out = ColorService.sortedAndDeduped([
            E(path: "/sys/sRGB.icc", name: "sRGB", isFactory: false),
            E(path: "/dev/srgb.icc", name: "SRGB", isFactory: true),
            E(path: "/lib/sRGB.icc", name: "sRGB", isFactory: false),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].path, "/dev/srgb.icc")
    }

    func testEmpty() {
        XCTAssertTrue(ColorService.sortedAndDeduped([]).isEmpty)
    }

    @MainActor
    func testReadOnlyQueriesDoNotCrash() {
        let s = ColorService()
        _ = s.presets(for: CGMainDisplayID())
        s.reloadProfiles()
        _ = s.currentPreset(for: CGMainDisplayID())
    }
}
