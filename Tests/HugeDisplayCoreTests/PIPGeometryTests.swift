import XCTest
@testable import HugeDisplayCore

final class PIPGeometryTests: XCTestCase {
    private let screen = CGRect(x: -2560, y: 100, width: 2560, height: 1440)

    func testFractionRoundTrip() throws {
        let frame = CGRect(x: -1000, y: 400, width: 640, height: 360)
        let fraction = try XCTUnwrap(PIPGeometry.fraction(of: frame, in: screen))
        XCTAssertEqual(fraction.x, 1560.0 / 2560.0, accuracy: 1e-9)
        XCTAssertEqual(fraction.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(PIPGeometry.frame(from: fraction, in: screen), frame)
    }

    func testFractionScalesToDifferentScreen() throws {
        let fraction = try XCTUnwrap(PIPGeometry.fraction(of: CGRect(x: -1280, y: 820, width: 640, height: 360), in: screen))
        let other = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let frame = PIPGeometry.frame(from: fraction, in: other)
        XCTAssertEqual(frame, CGRect(x: 640, y: 360, width: 320, height: 180))
    }

    func testFractionOfEmptyScreenIsNil() {
        XCTAssertNil(PIPGeometry.fraction(of: CGRect(x: 0, y: 0, width: 10, height: 10), in: .zero))
    }

    func testFitEnforcesAspectAndClampsInside() {
        let aspect = CGSize(width: 21, height: 9)
        let result = PIPGeometry.fit(CGRect(x: 2500, y: -50, width: 840, height: 500), aspect: aspect, in: screen)
        XCTAssertEqual(result.width / result.height, 21.0 / 9.0, accuracy: 1e-9)
        XCTAssertTrue(screen.contains(result))
    }

    func testFitShrinksToHeightWhenTooTall() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let result = PIPGeometry.fit(CGRect(x: 0, y: 0, width: 1000, height: 1000), aspect: CGSize(width: 1, height: 1), in: bounds)
        XCTAssertEqual(result.size, CGSize(width: 200, height: 200))
    }

    func testFitAppliesMinimumWidth() {
        let result = PIPGeometry.fit(CGRect(x: 0, y: 0, width: 20, height: 20), aspect: CGSize(width: 2, height: 1), in: screen)
        XCTAssertEqual(result.width, PIPGeometry.minPanelWidth)
        XCTAssertEqual(result.height, PIPGeometry.minPanelWidth / 2)
    }

    func testDefaultFrameIsBottomRightInsideBounds() {
        let frame = PIPGeometry.defaultFrame(aspect: CGSize(width: 16, height: 9), in: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.maxX, screen.maxX - 24, accuracy: 1e-9)
        XCTAssertEqual(frame.minY, screen.minY + 24, accuracy: 1e-9)
        XCTAssertEqual(frame.width, screen.width * 0.3, accuracy: 1e-9)
    }

    func testCaptureSizeScalesByBackingFactor() {
        let size = PIPGeometry.captureSize(panelSize: CGSize(width: 480, height: 202.5), scale: 2, sourcePixels: CGSize(width: 5120, height: 2160))
        XCTAssertEqual(size.width, 960)
        XCTAssertEqual(size.height, 405)
    }

    func testCaptureSizeCappedAtSourceKeepingAspect() {
        let size = PIPGeometry.captureSize(panelSize: CGSize(width: 3000, height: 1500), scale: 2, sourcePixels: CGSize(width: 2560, height: 1080))
        XCTAssertEqual(size.width, 2160) // height-limited: 1080 * (6000/3000)
        XCTAssertEqual(size.height, 1080)
    }

    func testCaptureSizeNeverZero() {
        let size = PIPGeometry.captureSize(panelSize: .zero, scale: 0, sourcePixels: CGSize(width: 100, height: 100))
        XCTAssertGreaterThanOrEqual(size.width, 2)
        XCTAssertGreaterThanOrEqual(size.height, 2)
    }

    func testSnapOpacity() {
        XCTAssertEqual(PIPGeometry.snapOpacity(0.9), 1)
        XCTAssertEqual(PIPGeometry.snapOpacity(0.7), 0.75)
        XCTAssertEqual(PIPGeometry.snapOpacity(0.1), 0.5)
    }

    func testSettingsCodableRoundTrip() throws {
        let settings = PIPSettings(
            frame: PIPFraction(x: 0.3, y: 0.3, width: 0.3, height: 0.3),
            hostScreen: DisplayKey(vendor: 1, model: 2, serial: 3),
            opacity: 0.5,
            clickThrough: true
        )
        let decoded = try JSONDecoder().decode(PIPSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
