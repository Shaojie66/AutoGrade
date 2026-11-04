import AppKit
import AutoGradeCore
import XCTest

/// DeepSeek title candidates in the app (CLAUDE.md 封面 / 云端候选 / App), with a
/// memory secret store, a throwaway UserDefaults suite and a fake transport:
/// no Keychain, no network, none of the app's real settings.
@MainActor
final class TitleSuggestionAppTests: XCTestCase {
    let clip = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/synthetic_cover.mp4")
    let key = "sk-apptest-00112233445566778899"
    private var suite: String!
    private var defaults: UserDefaults!

    final class MemorySecretStore: SecretStore, @unchecked Sendable {
        var value: String?
        init(_ value: String? = nil) { self.value = value }
        func read() -> String? { value }
        func write(_ secret: String) throws { value = secret }
        func delete() throws { value = nil }
    }

    final class FakeTransport: TitleTransport, @unchecked Sendable {
        var replies: [(Data, Int)]
        private(set) var sent: [URLRequest] = []
        init(_ replies: [(Data, Int)]) { self.replies = replies }
        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            sent.append(request)
            guard !replies.isEmpty else { return (Data(), 599) }
            return replies.removeFirst()
        }
    }

    func reply(_ titles: [String]) -> (Data, Int) {
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: ["titles": titles]), as: UTF8.self)
        return (try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), 200)
    }

    func messages(_ r: URLRequest) throws -> (system: String, user: String) {
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        let m = try XCTUnwrap(body["messages"] as? [[String: String]])
        return (try XCTUnwrap(m.first?["content"]), try XCTUnwrap(m.last?["content"]))
    }

    override func setUp() async throws {
        suite = "autograde.titletests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func wait(_ what: String, seconds: Double = 60, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); throw XCTSkip("timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func project(enabled: Bool, key: String?, _ transport: FakeTransport) -> (Project, TitleSuggestionSettings) {
        let settings = TitleSuggestionSettings(defaults: defaults, secrets: MemorySecretStore(key))
        settings.enabled = enabled
        return (Project(stylesDirectory: nil, titleSettings: settings, titleTransport: transport), settings)
    }

    func testOffByDefaultSendsNothing() {
        let settings = TitleSuggestionSettings(defaults: defaults, secrets: MemorySecretStore(key))
        XCTAssertFalse(settings.enabled, "off unless turned on")
        XCTAssertNil(settings.keyForRequest(), "no key handed out while off")
        let fake = FakeTransport([])
        let p = Project(stylesDirectory: nil, titleSettings: settings, titleTransport: fake)
        XCTAssertFalse(p.canSuggestTitles)
        p.suggestTitles()
        XCTAssertTrue(fake.sent.isEmpty)
        XCTAssertNil(p.titleSuggestionError)
    }

    func testOnWithoutAKeySendsNothing() {
        let fake = FakeTransport([])
        let (p, _) = project(enabled: true, key: nil, fake)
        p.suggestTitles()
        XCTAssertTrue(fake.sent.isEmpty)
        XCTAssertEqual(p.titleSuggestionError, L(S.titleNeedsKey))
    }

    /// The request carries the description, the 12-character limit for a 3:4 cover
    /// and the key in the header only; another batch sends what was offered; a picked
    /// candidate becomes the title and is drawn into the preview.
    func testCandidatesFromTheRequestToThePreview() async throws {
        let long = String(repeating: "长", count: 13)
        let fake = FakeTransport([reply(["漫画里的一天", "第二个候选", long]), reply(["换一批的标题"])])
        let (p, _) = project(enabled: true, key: key, fake)
        p.open(clip)
        try await wait("analysis") { p.phase == .ready }
        p.coverAspects = [.portrait3x4]
        p.coverTopicText = "漫画封面测试"
        XCTAssertTrue(p.titleInputIsThin, "no subtitles: the hint shows")
        XCTAssertEqual(p.titleSendCounts.topic, 6)
        XCTAssertEqual(p.titleSendCounts.subtitles, 0)

        p.suggestTitles()
        try await wait("candidates") { !p.suggestingTitles && !p.titleCandidates.isEmpty }
        XCTAssertEqual(p.titleCandidates, ["漫画里的一天", "第二个候选"], "the 13-character one is dropped, not cut")
        let first = try XCTUnwrap(fake.sent.first)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertFalse(String(decoding: try XCTUnwrap(first.httpBody), as: UTF8.self).contains(key), "the key is not in the body")
        let (system, user) = try messages(first)
        XCTAssertTrue(system.contains("不超过 12 个字"), "a 3:4 cover is tall: 12 characters")
        XCTAssertTrue(user.contains("主题：漫画封面测试"))
        XCTAssertFalse(user.contains("视频口播"), "no subtitles, none sent")

        p.suggestTitles(anotherBatch: true)
        try await wait("another batch") { !p.suggestingTitles && p.titleCandidates == ["换一批的标题"] }
        XCTAssertTrue(try messages(fake.sent[1]).user.contains("已经给过，换不同的说法：漫画里的一天；第二个候选"))
        XCTAssertEqual(p.offeredTitles, ["漫画里的一天", "第二个候选", "换一批的标题"])

        // picking a candidate fills the title, and the cover preview draws it
        p.findCovers()
        try await wait("covers") { p.covers != nil && p.busy == nil }
        p.selectCover(try XCTUnwrap(p.covers?.first).frame)
        try await wait("plain preview") { p.coverPreview != nil }
        let plain = p.coverPreview?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data as Data?
        p.useTitleCandidate("漫画里的一天")
        XCTAssertEqual(p.coverTitleText, "漫画里的一天")
        try await wait("titled preview") {
            (p.coverPreview?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data as Data?) != plain
        }
    }

    func testRefusedKeyIsReportedWithoutIt() async throws {
        let echoed = try JSONSerialization.data(withJSONObject: ["error": ["message": "Authentication Fails, Your api key: \(key) is invalid"]])
        let fake = FakeTransport([(echoed, 401)])
        let (p, _) = project(enabled: true, key: key, fake)
        p.open(clip)
        try await wait("analysis") { p.phase == .ready }
        p.coverTopicText = "测试"
        p.suggestTitles()
        try await wait("error") { !p.suggestingTitles && p.titleSuggestionError != nil }
        let error = try XCTUnwrap(p.titleSuggestionError)
        XCTAssertEqual(error, L(S.titleError(.http(status: 401, message: ""))))
        XCTAssertFalse(error.contains(key))
        XCTAssertEqual(fake.sent.count, 1, "not retried")
        XCTAssertTrue(p.titleCandidates.isEmpty)
    }

    func testTheKeyLivesInTheSecretStoreOnly() {
        let store = MemorySecretStore()
        let settings = TitleSuggestionSettings(defaults: defaults, secrets: store)
        settings.enabled = true
        settings.saveKey("  \(key)  ")
        XCTAssertEqual(store.value, key, "trimmed, in the secret store")
        XCTAssertTrue(settings.hasKey)
        let everything = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(everything.keys.sorted(), [TitleSuggestionSettings.enabledKey], "only the on/off flag is in UserDefaults")
        XCTAssertFalse("\(everything)".contains(key))
        XCTAssertEqual(settings.keyForRequest(), key)
        settings.deleteKey()
        XCTAssertFalse(settings.hasKey)
        XCTAssertNil(store.value)
        XCTAssertNil(settings.keyForRequest())
        // a reopened settings object reads the flag back, the key from the store
        let again = TitleSuggestionSettings(defaults: defaults, secrets: MemorySecretStore(key))
        XCTAssertTrue(again.enabled)
        XCTAssertTrue(again.hasKey)
    }
}
