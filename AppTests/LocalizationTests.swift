import XCTest

/// Language resolution and switching (App/Localization). Each test owns a
/// throwaway UserDefaults suite; the app's real settings are never read.
@MainActor
final class LocalizationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "autograde.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSwitchingChangesTextImmediatelyAndPersists() {
        let loc = Localization(defaults: defaults, preferred: { ["zh-Hans-CN"] })
        XCTAssertEqual(loc.setting, .system)
        XCTAssertEqual(loc.text(S.open), S.open.zh, "system zh-Hans -> Chinese")
        loc.setting = .english
        XCTAssertEqual(loc.text(S.open), S.open.en, "no relaunch needed")
        XCTAssertEqual(defaults.string(forKey: Localization.key), "english")
        XCTAssertEqual(Localization(defaults: defaults, preferred: { ["zh-Hans-CN"] }).text(S.open), S.open.en,
                       "a new launch reads the stored choice")
        loc.setting = .system
        XCTAssertEqual(loc.text(S.open), S.open.zh)
    }

    func testSystemResolution() {
        let cases: [([String], Language)] = [
            (["zh-Hans-CN"], .simplifiedChinese), (["zh-CN"], .simplifiedChinese), (["zh"], .simplifiedChinese),
            (["zh-Hant-TW"], .english), (["zh-HK"], .english), (["en-GB"], .english),
            (["fr-FR", "zh-Hans"], .simplifiedChinese), ([], .english),
        ]
        for (preferred, want) in cases {
            XCTAssertEqual(Localization.resolve(.system, preferred: preferred), want, "\(preferred)")
        }
    }

    func testObservationFiresOnLanguageChange() {
        let loc = Localization(defaults: defaults, preferred: { ["en-US"] })
        let fired = expectation(description: "language observed")
        withObservationTracking { _ = loc.language } onChange: { fired.fulfill() }
        loc.setting = .simplifiedChinese
        wait(for: [fired], timeout: 1)
    }
}
