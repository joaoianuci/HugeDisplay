import CoreGraphics
import XCTest
@testable import HugeDisplayCore

final class TogglePolicyTests: XCTestCase {
    private func physical(_ id: CGDirectDisplayID) -> ToggleDisplayInfo { ToggleDisplayInfo(id: id) }
    private func virtual(_ id: CGDirectDisplayID) -> ToggleDisplayInfo { ToggleDisplayInfo(id: id, isPhysical: false) }
    private func mirror(_ id: CGDirectDisplayID) -> ToggleDisplayInfo { ToggleDisplayInfo(id: id, isMirror: true) }
    private func asleep(_ id: CGDirectDisplayID) -> ToggleDisplayInfo { ToggleDisplayInfo(id: id, isAsleep: true) }

    // MARK: canDisable

    func testAllowsDisablingOneOfTwoActiveDisplays() {
        let active = [physical(1), physical(3)]
        XCTAssertEqual(TogglePolicy.canDisable(target: 1, active: active, online: [1, 3]), .allowed)
        XCTAssertEqual(TogglePolicy.canDisable(target: 3, active: active, online: [1, 3]), .allowed)
    }

    func testRefusesLastActiveDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 1, active: [physical(1)], online: [1, 3]) else {
            return XCTFail("must refuse the last active display")
        }
    }

    func testRefusesOfflineDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 9, active: [physical(1), physical(3)], online: [1, 3]) else {
            return XCTFail("must refuse an offline display")
        }
    }

    func testRefusesAlreadyInactiveDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 3, active: [physical(1)], online: [1, 3]) else {
            return XCTFail("must refuse a display that is already off")
        }
    }

    func testVirtualDisplayDoesNotCountAsAnotherDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 1, active: [physical(1), virtual(7)], online: [1, 7]) else {
            return XCTFail("a virtual display must not make the only physical display disableable")
        }
    }

    func testMirrorDoesNotCountAsAnotherDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 1, active: [physical(1), mirror(4)], online: [1, 4]) else {
            return XCTFail("a mirror must not count as another display")
        }
    }

    func testAsleepDisplayDoesNotCountAsAnotherDisplay() {
        guard case .refused = TogglePolicy.canDisable(target: 1, active: [physical(1), asleep(3)], online: [1, 3]) else {
            return XCTFail("an asleep display must not count as another display")
        }
    }

    func testVirtualDisplayCanBeDisabledWhenPhysicalOneRemains() {
        XCTAssertEqual(TogglePolicy.canDisable(target: 7, active: [physical(1), virtual(7)], online: [1, 7]), .allowed)
    }

    func testAnyUsableOtherDisplayIsEnough() {
        let active = [physical(1), virtual(7), mirror(4), physical(3)]
        XCTAssertEqual(TogglePolicy.canDisable(target: 1, active: active, online: [1, 7, 4, 3]), .allowed)
    }

    // MARK: needsRecovery

    func testNoRecoveryWithoutDisabledDisplays() {
        XCTAssertFalse(TogglePolicy.needsRecovery(active: [], disabledByUs: []))
    }

    func testRecoveryWhenNoActiveDisplays() {
        XCTAssertTrue(TogglePolicy.needsRecovery(active: [], disabledByUs: [1]))
    }

    func testNoRecoveryWhileAnotherPhysicalDisplayIsActive() {
        XCTAssertFalse(TogglePolicy.needsRecovery(active: [physical(3)], disabledByUs: [1]))
    }

    func testRecoveryWhenOnlyVirtualDisplayIsLeft() {
        XCTAssertTrue(TogglePolicy.needsRecovery(active: [virtual(7)], disabledByUs: [1]))
    }

    func testRecoveryWhenOnlyMirrorOrAsleepDisplaysAreLeft() {
        XCTAssertTrue(TogglePolicy.needsRecovery(active: [mirror(4), asleep(3)], disabledByUs: [1]))
    }

    // MARK: resolution / reconciliation

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

    func testResolveIDPrefersInactiveDisplayAmongIdenticalKeys() {
        let key = DisplayKey(vendor: 1, model: 2, serial: 0)
        let entry = DisabledDisplay(id: 5, key: key)
        let online = [(id: CGDirectDisplayID(5), key: key), (id: CGDirectDisplayID(6), key: key)]
        // 5 is active (the twin), 6 is the one that is off.
        XCTAssertEqual(TogglePolicy.resolveID(for: entry, online: online, active: [5]), 6)
    }

    func testResolveAllClassifiesEntries() {
        let a = DisplayKey(vendor: 1, model: 1, serial: 1)
        let b = DisplayKey(vendor: 2, model: 2, serial: 2)
        let c = DisplayKey(vendor: 3, model: 3, serial: 3)
        let entries = [DisabledDisplay(id: 10, key: a), DisabledDisplay(id: 20, key: b), DisabledDisplay(id: 30, key: c)]
        let online = [(id: CGDirectDisplayID(11), key: a), (id: CGDirectDisplayID(20), key: b)]
        let result = TogglePolicy.resolveAll(entries, online: online, active: [20])
        XCTAssertEqual(result.map(\.status), [.inactive(11), .active(20), .offline])
    }

    func testReconciledDropsActiveKeepsOfflineAndRefreshesIDs() {
        let a = DisplayKey(vendor: 1, model: 1, serial: 1)
        let b = DisplayKey(vendor: 2, model: 2, serial: 2)
        let c = DisplayKey(vendor: 3, model: 3, serial: 3)
        let entries = [DisabledDisplay(id: 10, key: a), DisabledDisplay(id: 20, key: b), DisabledDisplay(id: 30, key: c)]
        let online = [(id: CGDirectDisplayID(11), key: a), (id: CGDirectDisplayID(20), key: b)]
        let kept = TogglePolicy.reconciled(entries, online: online, active: [20])
        XCTAssertEqual(kept, [DisabledDisplay(id: 11, key: a), DisabledDisplay(id: 30, key: c)])
        // Idempotent.
        XCTAssertEqual(TogglePolicy.reconciled(kept, online: online, active: [20]), kept)
    }

    func testReconciledCollapsesStaleDuplicatesOfTheSameDisplay() {
        let key = DisplayKey(vendor: 1, model: 1, serial: 1)
        let entries = [DisabledDisplay(id: 10, key: key), DisabledDisplay(id: 12, key: key)]
        let kept = TogglePolicy.reconciled(entries, online: [(id: 11, key: key)], active: [])
        XCTAssertEqual(kept.count, 1)
    }

    func testReconciledDropsEverythingOnceDisplayIsActive() {
        let key = DisplayKey(vendor: 1, model: 1, serial: 1)
        let entries = [DisabledDisplay(id: 10, key: key)]
        XCTAssertTrue(TogglePolicy.reconciled(entries, online: [(id: 10, key: key)], active: [10]).isEmpty)
    }

    // MARK: store

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

    func testStoreKeepsIdenticalTwinsAndRemovesExactEntry() throws {
        let suite = "HugeDisplayTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisabledDisplayStore(defaults: defaults)
        let key = DisplayKey(vendor: 1, model: 2, serial: 0)
        let a = DisabledDisplay(id: 5, key: key)
        let b = DisabledDisplay(id: 6, key: key)
        store.add(a)
        store.add(b)
        store.add(b)
        XCTAssertEqual(store.all, [a, b])
        store.remove(a)
        XCTAssertEqual(store.all, [b])
        store.replaceAll([])
        XCTAssertTrue(store.all.isEmpty)
    }
}
