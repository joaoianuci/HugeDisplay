import XCTest
@testable import HugeDisplayCore

/// Guards the translations: no key may exist in English without a pt-BR and es counterpart,
/// and the three languages must agree on printf-style format specifiers.
final class LocalizationTests: XCTestCase {
    private static let languages = ["en", "pt-BR", "es"]

    // MARK: - Helpers

    /// Parses a .strings file (old-style plist) into a dictionary.
    private func table(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(url.path) is not a string table")
    }

    private func coreTable(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            "Core bundle has no \(language).lproj/Localizable.strings"
        )
        return try table(at: url)
    }

    /// Format specifiers in order of appearance ("%lld", "%@", "%.2f", ...), `%%` ignored.
    private func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?!%)[-+ 0#]*\\d*(?:\\.\\d+)?(?:ll|l|h|hh|q|z|t|j)?[a-zA-Z@]")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    // MARK: - Core bundle

    func testCoreBundleShipsAllThreeLanguages() {
        for language in Self.languages {
            XCTAssertTrue(Bundle.module.localizations.contains(language), "Missing \(language).lproj in the Core bundle")
        }
    }

    func testEveryEnglishKeyIsTranslated() throws {
        let en = try coreTable("en")
        XCTAssertFalse(en.isEmpty)
        for language in ["pt-BR", "es"] {
            let other = try coreTable(language)
            let missing = Set(en.keys).subtracting(other.keys)
            XCTAssertTrue(missing.isEmpty, "\(language) is missing: \(missing.sorted())")
            let extra = Set(other.keys).subtracting(en.keys)
            XCTAssertTrue(extra.isEmpty, "\(language) has keys unknown to en: \(extra.sorted())")
            for (key, value) in other {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \"\(key)\" is empty")
                XCTAssertEqual(specifiers(value), specifiers(key), "\(language) \"\(key)\" changes the format specifiers")
            }
        }
    }

    func testEnglishValuesEqualKeys() throws {
        for (key, value) in try coreTable("en") {
            XCTAssertEqual(key, value)
        }
    }

    func testKnownKeysDifferFromEnglish() throws {
        let key = "Close"
        let en = try coreTable("en")
        XCTAssertEqual(en[key], "Close")
        XCTAssertEqual(try coreTable("pt-BR")[key], "Fechar")
        XCTAssertEqual(try coreTable("es")[key], "Cerrar")
        XCTAssertNotEqual(try coreTable("pt-BR")[key], en[key])
        XCTAssertNotEqual(try coreTable("es")[key], en[key])
    }

    /// `String(localized:bundle:)` must resolve through the same lproj tables for a given language.
    func testLookupResolvesPerLanguage() throws {
        for (language, expected) in [("en", "Close"), ("pt-BR", "Fechar"), ("es", "Cerrar")] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Close", value: nil, table: nil), expected)
        }
    }

    /// Keys with interpolations must resolve to translated, correctly-substituted text.
    func testInterpolatedFormatKeys() throws {
        let path = try XCTUnwrap(Bundle.module.path(forResource: "pt-BR", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let format = bundle.localizedString(forKey: "Display %lld", value: nil, table: nil)
        XCTAssertEqual(String(format: format, 3), "Monitor 3")
    }

    // MARK: - Source keys

    /// Every `String(localized: "...", bundle: .module)` in Sources/HugeDisplayCore must have an entry in the
    /// string tables. Interpolations are compared by position (`%?`), because the exact specifier depends on
    /// the interpolated type (Int -> %lld, String -> %@).
    func testSourceKeysExistInTables() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HugeDisplayCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)

        func normalise(_ key: String) -> String {
            let regex = try! NSRegularExpression(pattern: "%(?!%)[-+ 0#]*\\d*(?:\\.\\d+)?(?:ll|l|h|hh|q|z|t|j)?[a-zA-Z@]")
            return regex.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "%?")
        }
        let tableKeys = Set(try coreTable("en").keys.map(normalise))

        var found = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var rest = text[...]
            while let start = rest.range(of: "String(localized: \"") {
                rest = rest[start.upperBound...]
                // Read the literal up to its closing quote, replacing balanced \( ... ) interpolations.
                var key = ""
                var chars = rest.makeIterator()
                var consumed = 0
                scan: while let c = chars.next() {
                    consumed += 1
                    switch c {
                    case "\\":
                        guard let n = chars.next() else { break scan }
                        consumed += 1
                        if n == "(" {
                            var depth = 1
                            while depth > 0, let d = chars.next() {
                                consumed += 1
                                if d == "(" { depth += 1 } else if d == ")" { depth -= 1 }
                            }
                            key += "%?"
                        } else if n == "\"" {
                            key += "\""
                        } else {
                            key.append(n)
                        }
                    case "\"": break scan
                    default: key.append(c)
                    }
                }
                rest = rest.dropFirst(consumed)
                found += 1
                XCTAssertTrue(tableKeys.contains(normalise(key)), "\(file.lastPathComponent): no translation entry for \"\(key)\"")
            }
        }
        XCTAssertGreaterThan(found, 20, "Expected to find the Core String(localized:) calls")
    }

    /// Runtime messages must come from the Core bundle in the current language (whatever it is).
    func testRefusalMessagesAreLocalized() throws {
        guard case .refused(let message) = TogglePolicy.canDisable(target: 1, active: [], online: [1]) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(message, Bundle.module.localizedString(forKey: "That display is already turned off.", value: nil, table: nil))
    }

    // MARK: - App target (Resources/*.lproj in the repo, shipped by scripts/build-app.sh)

    private var appResources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HugeDisplayCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources")
    }

    private func appTable(_ language: String, _ name: String) throws -> [String: String] {
        try table(at: appResources.appendingPathComponent("\(language).lproj/\(name).strings"))
    }

    func testAppLocalizableKeysAreInAllLanguages() throws {
        let en = try appTable("en", "Localizable")
        XCTAssertFalse(en.isEmpty)
        for language in ["pt-BR", "es"] {
            let other = try appTable(language, "Localizable")
            XCTAssertEqual(Set(en.keys), Set(other.keys), "\(language) Localizable.strings key set differs from en")
            for (key, value) in other {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \"\(key)\" is empty")
                XCTAssertEqual(specifiers(value), specifiers(key), "\(language) \"\(key)\" changes the format specifiers")
            }
        }
        XCTAssertEqual(try appTable("pt-BR", "Localizable")["Quit"], "Sair")
        XCTAssertEqual(try appTable("es", "Localizable")["Quit"], "Salir")
    }

    func testAppInfoPlistStringsAreInAllLanguages() throws {
        let en = try appTable("en", "InfoPlist")
        XCTAssertNotNil(en["NSScreenCaptureUsageDescription"])
        for language in ["pt-BR", "es"] {
            let other = try appTable(language, "InfoPlist")
            XCTAssertEqual(Set(en.keys), Set(other.keys))
            XCTAssertNotEqual(other["NSScreenCaptureUsageDescription"], en["NSScreenCaptureUsageDescription"])
        }
    }

    func testInfoPlistDeclaresLocalizations() throws {
        let data = try Data(contentsOf: appResources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(plist["CFBundleLocalizations"] as? [String], Self.languages)
    }
}
