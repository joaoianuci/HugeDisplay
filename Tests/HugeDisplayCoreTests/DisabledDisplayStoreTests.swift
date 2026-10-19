import XCTest
@testable import HugeDisplayCore

final class DisabledDisplayStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "DisabledDisplayStoreTests")
        defaults.removePersistentDomain(forName: "DisabledDisplayStoreTests")
    }

    func testIdentityIgnoresDescriptiveFields() {
        let key = DisplayKey(vendor: 7789, model: 30484, serial: 0)
        XCTAssertEqual(DisabledDisplay(id: 3, key: key, name: "LG", isBuiltin: false, disabledAt: Date()),
                       DisabledDisplay(id: 3, key: key))
    }

    func testRemoveMatchesEntryWithoutMetadata() {
        let store = DisabledDisplayStore(defaults: defaults)
        let key = DisplayKey(vendor: 7789, model: 30484, serial: 0)
        store.add(DisabledDisplay(id: 3, key: key, name: "LG", isBuiltin: false, disabledAt: Date()))
        store.remove(DisabledDisplay(id: 3, key: key))
        XCTAssertTrue(store.all.isEmpty)
    }

    func testDecodesEntriesWrittenBeforeMetadataExisted() throws {
        let legacy = #"[{"id":3,"key":{"vendor":7789,"model":30484,"serial":0}}]"#
        defaults.set(Data(legacy.utf8), forKey: DisabledDisplayStore.defaultsKey)
        let entries = DisabledDisplayStore(defaults: defaults).all
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.name)
    }
}
