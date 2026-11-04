import AutoGradeCore
import XCTest

/// DeepSeek title candidates (CLAUDE.md 封面 / 云端候选), never on the network:
/// a fake transport checks what would be sent and plays back replies.
final class TitleSuggesterTests: XCTestCase {
    let key = "sk-test-0123456789abcdef"

    /// Plays back `replies` in order and records every request.
    final class FakeTransport: TitleTransport, @unchecked Sendable {
        var replies: [(Data, Int)]
        private(set) var sent: [URLRequest] = []
        init(_ replies: [(Data, Int)]) { self.replies = replies }
        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            sent.append(request)
            guard !replies.isEmpty else { return (Data(), 599) }   // an unexpected extra request: fail, do not crash
            let r = replies.removeFirst()
            return (r.0, r.1)
        }
    }

    /// A chat completion whose message content is `content`.
    func reply(_ content: String, status: Int = 200) -> (Data, Int) {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return (try! JSONSerialization.data(withJSONObject: body), status)
    }

    func titles(_ t: [String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["titles": t]), as: UTF8.self)
    }

    func body(_ req: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
    }

    func testRequestIsWhatTheRulesSay() throws {
        let long = String(repeating: "篮球馆", count: 1000)                      // 3000 characters
        let req = TitleSuggester.request(TitleRequest(topic: "训练", transcript: long, limit: 12), key: key)
        XCTAssertEqual(req.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.timeoutInterval, 15)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let b = try body(req)
        XCTAssertEqual(b["model"] as? String, "deepseek-flash")
        XCTAssertEqual((b["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((b["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual(b["max_tokens"] as? Int, 300)
        XCTAssertEqual(b["stream"] as? Bool, false)
        let messages = try XCTUnwrap(b["messages"] as? [[String: String]])
        let system = try XCTUnwrap(messages.first?["content"]), user = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(system.contains("json"), "JSON mode needs the word json in the prompt")
        XCTAssertTrue(system.contains("不超过 12 个字"))
        XCTAssertTrue(user.contains("主题：训练"))
        let sent = try XCTUnwrap(user.components(separatedBy: "视频口播：").last?.components(separatedBy: "\n").first)
        XCTAssertEqual(sent.count, 2000, "the transcript is cut to 2000 characters")
        XCTAssertFalse(user.contains("画面"), "no image labels are sent")
        // the key is in the header and nowhere in the body
        XCTAssertFalse(String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self).contains(key))
    }

    func testAnotherBatchSendsWhatWasOffered() throws {
        let req = TitleSuggester.request(TitleRequest(transcript: "第一次骑马", exclude: ["草原骑马", "第一次骑马"]), key: key)
        let user = try XCTUnwrap((try body(req)["messages"] as? [[String: String]])?.last?["content"])
        XCTAssertTrue(user.contains("已经给过，换不同的说法：草原骑马；第一次骑马"))
    }

    func testFilterDropsEmptyLongRepeatedAndOffered() {
        let out = TitleSuggester.filter(["  草原骑马  ", "", "草原骑马", String(repeating: "长", count: 17), "已给过", "马很听话", "AutoGrade调色"],
                                        limit: 16, exclude: ["已给过"])
        XCTAssertEqual(out, ["草原骑马", "马很听话", "AutoGrade调色"])
        XCTAssertEqual(TitleSuggester.length("AutoGrade 调色"), 11, "letters count one each, spaces do not")
    }

    func testReturnsFilteredTitles() async throws {
        let fake = FakeTransport([reply(titles(["第一次草原骑马", "马很听话走了一下午", String(repeating: "超", count: 20)]))])
        let got = try await TitleSuggester.suggest(TitleRequest(transcript: "第一次在草原上骑马"), key: key, transport: fake)
        XCTAssertEqual(got, ["第一次草原骑马", "马很听话走了一下午"])
        XCTAssertEqual(fake.sent.count, 1)
    }

    func testBlankContentIsRetriedOnce() async throws {
        // JSON mode may return blank content (spaces): one retry
        let fake = FakeTransport([reply("   "), reply(titles(["第一次草原骑马"]))])
        let got = try await TitleSuggester.suggest(TitleRequest(transcript: "骑马"), key: key, transport: fake)
        XCTAssertEqual(got, ["第一次草原骑马"])
        XCTAssertEqual(fake.sent.count, 2)

        let twice = FakeTransport([reply("not json"), reply("   ")])
        do {
            _ = try await TitleSuggester.suggest(TitleRequest(transcript: "骑马"), key: key, transport: twice)
            XCTFail("expected badResponse")
        } catch let e as TitleSuggestionError {
            XCTAssertEqual(e, .badResponse)
        }
        XCTAssertEqual(twice.sent.count, 2, "no third try")
    }

    func testHTTPErrorsAreNotRetriedAndNeverShowTheKey() async throws {
        let echoed = try JSONSerialization.data(withJSONObject: ["error": ["message": "Authentication Fails, Your api key: sk-test-****cdef is invalid. \(key)"]])
        for status in [401, 402, 429, 500] {
            let fake = FakeTransport([(echoed, status)])
            do {
                _ = try await TitleSuggester.suggest(TitleRequest(transcript: "骑马"), key: key, transport: fake)
                XCTFail("expected an HTTP error")
            } catch let e as TitleSuggestionError {
                guard case .http(let s, let message) = e else { return XCTFail("\(e)") }
                XCTAssertEqual(s, status)
                for text in [e.description, message, "\(e)", String(reflecting: e)] {
                    XCTAssertFalse(text.contains(key), "status \(status): the key leaked")
                    XCTAssertFalse(text.contains("sk-"), "status \(status): a masked key leaked: \(text)")
                    XCTAssertFalse(text.contains("cdef"), "status \(status): the key's tail leaked: \(text)")
                }
            }
            XCTAssertEqual(fake.sent.count, 1, "status \(status) is not retried")
        }
    }

    /// Each redaction layer on its own: a masked key that shares nothing with ours.
    func testMaskedKeysOfAnyShapeAreRemoved() async throws {
        let other = try JSONSerialization.data(withJSONObject: ["error": ["message": "Incorrect API key provided: sk-zz9***q1 (see docs)"]])
        let fake = FakeTransport([(other, 401)])
        do {
            _ = try await TitleSuggester.suggest(TitleRequest(transcript: "骑马"), key: key, transport: fake)
            XCTFail("expected an HTTP error")
        } catch let e as TitleSuggestionError {
            guard case .http(_, let message) = e else { return XCTFail("\(e)") }
            XCTAssertFalse(message.contains("sk-zz9"), message)
            XCTAssertFalse(message.contains("***"), message)
            XCTAssertTrue(message.contains("[redacted]"), message)
        }
    }

    func testNothingUsableAndNoInput() async throws {
        let fake = FakeTransport([reply(titles([String(repeating: "超", count: 30), "  "]))])
        do {
            _ = try await TitleSuggester.suggest(TitleRequest(transcript: "骑马"), key: key, transport: fake)
            XCTFail("expected noUsableTitles")
        } catch let e as TitleSuggestionError { XCTAssertEqual(e, .noUsableTitles) }

        let none = FakeTransport([])
        do {
            _ = try await TitleSuggester.suggest(TitleRequest(topic: "  ", transcript: ""), key: key, transport: none)
            XCTFail("expected noInput")
        } catch let e as TitleSuggestionError { XCTAssertEqual(e, .noInput) }
        XCTAssertEqual(none.sent.count, 0, "nothing is sent without input")
    }

    func testThinInput() {
        XCTAssertTrue(TitleRequest(topic: "伊斯坦布尔日落").isThin, "a topic alone gives near-identical candidates")
        XCTAssertFalse(TitleRequest(topic: "日落", transcript: "在老港口走了一下午").isThin)
    }
}
