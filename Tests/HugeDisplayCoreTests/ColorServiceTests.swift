import ColorSync
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

    func testDedupeKeepsCurrentProfileEntry() {
        let out = ColorService.sortedAndDeduped([
            E(path: "/dev/srgb.icc", name: "sRGB", isFactory: true),
            E(path: "/lib/sRGB Profile.icc", name: "sRGB", isFactory: false),
        ], keeping: "/lib/sRGB Profile.icc")
        XCTAssertEqual(out.map(\.path), ["/lib/sRGB Profile.icc"])
    }

    func testDedupeCollapsesSamePath() {
        let out = ColorService.sortedAndDeduped([
            E(path: "/a.icc", name: "A", isFactory: false),
            E(path: "/a.icc", name: "B", isFactory: true),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].name, "B")
    }

    func testProfileKeysDefaultThenCustomModes() {
        XCTAssertEqual(ColorService.profileKeys(defaultModeID: "HDMI HD", customKeys: ["HDMI HD"]), ["HDMI HD"])
        XCTAssertEqual(ColorService.profileKeys(defaultModeID: "HDMI HD", customKeys: ["HDMI SD", "HDMI HD"]), ["HDMI HD", "HDMI SD"])
        XCTAssertEqual(ColorService.profileKeys(defaultModeID: nil, customKeys: ["X"]), ["X"])
        XCTAssertEqual(ColorService.profileKeys(defaultModeID: nil, customKeys: []), [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String])
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

    @MainActor
    func testCurrentPresetIsInPresets() {
        let s = ColorService()
        for id in [CGMainDisplayID()] {
            if let current = s.currentPreset(for: id) {
                XCTAssertTrue(s.presets(for: id).contains(current))
            }
        }
    }
}
