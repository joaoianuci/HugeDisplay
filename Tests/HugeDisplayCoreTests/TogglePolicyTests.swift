import CoreGraphics
import XCTest
@testable import HugeDisplayCore

final class TogglePolicyTests: XCTestCase {
    func testAllowsDisablingOneOfTwoActiveDisplays() {
        XCTAssertEqual(TogglePolicy.canDisable(target: 1, active: [1, 3], online: [1, 3]), .allowed)
        XCTAssertEqual(TogglePolicy.canDisable(target: 3, active: [1, 3], online: [1, 3]), .allowed)
    }

    func testRefusesLastActiveDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 1, active: [1], online: [1, 3]) else {
            return XCTFail("must refuse the last active display")
        }
    }

    func testRefusesOfflineDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 9, active: [1, 3], online: [1, 3]) else {
            return XCTFail("must refuse an offline display")
        }
    }

    func testRefusesAlreadyInactiveDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 3, active: [1], online: [1, 3]) else {
            return XCTFail("must refuse a display that is already off")
        }
    }

    func testNoRecoveryWithoutDisabledDisplays() {
        XCTAssertFalse(TogglePolicy.needsRecovery(active: [], online: [], disabledByUs: []))
    }

    func testRecoveryWhenNoActiveDisplays() {
        XCTAssertTrue(TogglePolicy.needsRecovery(active: [], online: [1], disabledByUs: [1]))
    }

    func testRecoveryWhenOnlyDisabledDisplaysRemainOnline() {
        XCTAssertTrue(TogglePolicy.needsRecovery(active: [3], online: [1], disabledByUs: [1]))
    }

    func testNoRecoveryWhileAnotherDisplayIsActive() {
        XCTAssertFalse(TogglePolicy.needsRecovery(active: [3], online: [1, 3], disabledByUs: [1]))
    }

    func testResolveIDPrefersSameIDAndKey() {
        let key = DisplayKey(vendor: 1, model: 2, serial: 3)
        let entry = DisabledDisplay(id: 5, key: key)
        let online = [(id: CGDirectDisplayID(7), key: key), (id: CGDirectDisplayID(5), key: key)]
        XCTAssertEqual(TogglePolicy.resolveID(for: entry, online: online), 5)
    }

    func testResolveIDFallsBackToKeyWhenIDChanged() {
        let key = DisplayKey(vendor: 1, model: 2, serial: 3)
        let other = DisplayKey(vendor: 9, model: 9, serial: 9)
        let entry = DisabledDisplay(id: 5, key: key)
        let online = [(id: CGDirectDisplayID(5), key: other), (id: CGDirectDisplayID(8), key: key)]
        XCTAssertEqual(TogglePolicy.resolveID(for: entry, online: online), 8)
        XCTAssertNil(TogglePolicy.resolveID(for: entry, online: [(id: 5, key: other)]))
    }

    func testStorePersistsAndRemoves() throws {
        let suite = "HugeDisplayTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisabledDisplayStore(defaults: defaults)
        XCTAssertTrue(store.all.isEmpty)

        let entry = DisabledDisplay(id: 1, key: DisplayKey(vendor: 1552, model: 41059, serial: 0))
        store.add(entry)
        XCTAssertEqual(DisabledDisplayStore(defaults: defaults).all, [entry])

        store.remove(id: 1)
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(defaults.data(forKey: "disabledDisplays"))
    }
}
