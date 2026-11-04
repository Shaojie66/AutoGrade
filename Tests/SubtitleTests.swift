import AutoGradeCore
import XCTest

/// Cue splitting and SRT / WebVTT in and out (CLAUDE.md 字幕). Pure functions,
/// synthetic tokens.
final class SubtitleTests: XCTestCase {
    let frame = 1.0 / 30

    /// Consecutive tokens, `seconds` each, no gaps, starting at `from`.
    func run(_ words: [String], from: Double = 0, seconds: Double = 0.2) -> [SubtitleToken] {
        words.enumerated().map { i, w in SubtitleToken(text: w, start: from + Double(i) * seconds, end: from + Double(i + 1) * seconds) }
    }

    func cues(_ t: [SubtitleToken], cuts: [Double] = [], script: SubtitleScript = .cjk, vertical: Bool = false) -> [SubtitleCue] {
        Subtitles.cues(tokens: t, cuts: cuts, frameSeconds: frame, script: script, vertical: vertical)
    }

    // MARK: splitting

    func testPausesAndSentenceEndsBreak() {
        let t = run(["今天", "天气", "很好。", "我们"]) + run(["出去"], from: 1.5)   // 0.7 s pause before 出去
        let c = cues(t)
        XCTAssertEqual(c.map(\.text), ["今天天气很好。", "我们", "出去"])
    }

    func testPunctuationTokensDoNotHideThePause() {
        // as the recogniser returns them: "，" is a token spanning the pause
        let t = [SubtitleToken(text: "好", start: 1.08, end: 1.26), SubtitleToken(text: " ，", start: 1.26, end: 1.68),
                 SubtitleToken(text: "我", start: 1.9, end: 2.0)]
        let c = cues(t)
        XCTAssertEqual(c.map(\.text), ["好，", "我"], "the 0.64 s pause after 好 still breaks")
        XCTAssertEqual(c[0].start, 1.08)
    }

    func testChineseIsOneLineAndEnglishUpToTwo() {
        let chars = (0..<20).map { String(UnicodeScalar(0x4E00 + $0)!) }
        let zh = cues(run(chars, seconds: 0.1), vertical: true)        // 20 > 12: two one-line cues
        XCTAssertEqual(zh.map(\.lines.count), [1, 1])
        XCTAssertTrue(zh.allSatisfy { $0.lines[0].count <= 12 }, "\(zh.map(\.lines))")
        let words = (0..<10).map { _ in " words" }                     // 59 chars: two lines of a 32-char limit
        let en = cues(run(words, seconds: 0.1), script: .latin, vertical: true)
        XCTAssertEqual(en.count, 1)
        XCTAssertEqual(en[0].lines.count, 2)
        XCTAssertTrue(en[0].lines.allSatisfy { $0.count <= 32 }, "\(en[0].lines)")
    }

    func testChineseBreaksBetweenWordsNotInsideThem() {
        // one character per token, no pauses: 15 characters, then 训练: the 16-char limit lands inside it
        let text = "我们今天来练习投篮然后开始努力训练"
        XCTAssertEqual(text.count, 17)
        let t = run(text.map { String($0) } + ["。"], seconds: 0.2)
        let c = cues(t)
        XCTAssertEqual(c.map(\.text), ["我们今天来练习投篮然后开始努力", "训练。"])
        XCTAssertFalse(c[0].text.hasSuffix("训"), "\(c.map(\.text))")
        XCTAssertFalse(c.last!.text.hasPrefix("练"), "\(c.map(\.text))")
    }

    func testTooLongBreaksAtTheWidestNearbyGap() {
        // 14 characters, a small gap after the 9th: break there, not at the 13th
        var t = run((0..<9).map { _ in "字" }, seconds: 0.2)
        t += run((0..<5).map { _ in "词" }, from: 1.85, seconds: 0.2)
        let c = cues(t, vertical: true)
        XCTAssertEqual(c.map { $0.text.count }, [9, 5])
    }

    func testTooLongBreaksAfterTheLastClauseMark() {
        let words = ["我们", "今天", "去", "公园，", "然后", "去", "博物馆", "看", "展览", "再", "和", "朋友们", "一起", "去", "吃饭"]
        let c = cues(run(words), vertical: true)                       // 27 chars > 2 x 12
        XCTAssertEqual(c.first?.text, "我们今天去公园，")
    }

    func testAtMostSixSeconds() {
        let c = cues(run((0..<40).map { _ in "字" }, seconds: 0.2), script: .cjk)   // 8 s, 40 chars <= 32? no: 2 x 16
        XCTAssertTrue(c.allSatisfy { $0.end - $0.start <= Subtitles.maxSeconds + Subtitles.holdSeconds + 1e-9 }, "\(c)")
        let long = cues(run((0..<12).map { _ in " word" }, seconds: 0.7), script: .latin)   // 8.4 s, short text
        XCTAssertGreaterThan(long.count, 1, "split by time even when the text is short")
    }

    func testACutInContinuousSpeechDoesNotSplitWords() {
        // one character per token, no pauses, a cut at 1.0 s in the middle of a word
        let t = run(["欢", "迎", "来", "到", "篮", "球", "馆", "练", "习"], from: 0.2, seconds: 0.2)
        let c = cues(t, cuts: [1.05])
        XCTAssertEqual(c.map(\.text), ["欢迎来到篮球馆练习"], "no single-character cues around the cut")
    }

    func testACutSplitsOnceAtTheLongestNearbyPause() {
        var t = run(["今", "天", "我", "们"], from: 0, seconds: 0.2)                  // 0 - 0.8
        t += run(["来", "练", "习"], from: 0.95, seconds: 0.2)                         // 0.15 s pause at 0.8
        let c = cues(t, cuts: [0.9])
        XCTAssertEqual(c.map(\.text), ["今天我们", "来练习"])
    }

    func testACutInsideACueSplitsIt() {
        let t = [SubtitleToken(text: "镜头", start: 0.5, end: 0.94), SubtitleToken(text: "切换", start: 1.06, end: 1.5)]   // 0.12 s gap
        XCTAssertEqual(cues(t).count, 1, "no cut: one cue")
        XCTAssertEqual(cues(t, cuts: [1.0]).map(\.text), ["镜头", "切换"])
        XCTAssertEqual(cues(t, cuts: [2.0]).count, 1, "a cut far from any word boundary does not split")
    }

    func testMinimumDurationHoldAndGap() {
        let alone = cues([SubtitleToken(text: "嗯", start: 1, end: 1.2)])
        XCTAssertEqual(alone[0].end, 1.8, accuracy: 1e-9, "at least 0.8 s")
        let pair = cues([SubtitleToken(text: "好。", start: 1, end: 1.2), SubtitleToken(text: "走", start: 1.5, end: 2.0)])
        XCTAssertEqual(pair[0].end, 1.5 - 2 * frame, accuracy: 1e-9, "stops 2 frames before the next cue")
        let held = cues([SubtitleToken(text: "好。", start: 1, end: 1.9), SubtitleToken(text: "走", start: 3, end: 3.5)])
        XCTAssertEqual(held[0].end, 2.1, accuracy: 1e-9, "0.2 s after the last word")
    }

    func testLatinJoinsWithSpacesAndCJKWithout() {
        XCTAssertEqual(cues(run([" Hello", " world."]), script: .latin).first?.text, "Hello world.")
        XCTAssertEqual(cues(run(["用", " AutoGrade ", "调色"])).first?.text, "用AutoGrade调色")
        XCTAssertEqual(SubtitleScript(language: "zh_CN"), .cjk)
        XCTAssertEqual(SubtitleScript(language: "en-US"), .latin)
    }

    func testCueAtTime() {
        let c = [SubtitleCue(start: 1, end: 2, lines: ["a"]), SubtitleCue(start: 3, end: 4, lines: ["b"])]
        XCTAssertNil(Subtitles.cue(at: 0.5, in: c))
        XCTAssertEqual(Subtitles.cue(at: 1, in: c), 0)
        XCTAssertNil(Subtitles.cue(at: 2, in: c), "end is exclusive")
        XCTAssertEqual(Subtitles.cue(at: 3.99, in: c), 1)
    }

    // MARK: SRT / WebVTT

    let sample = [SubtitleCue(start: 0.1, end: 1.2345, lines: ["第一行", "第二行"]),
                  SubtitleCue(start: 3723.0004, end: 3723.0996, lines: ["over an hour"])]

    func testSRTIsExact() {
        XCTAssertEqual(Subtitles.srt(sample),
                       "1\r\n00:00:00,100 --> 00:00:01,235\r\n第一行\r\n第二行\r\n\r\n"
                       + "2\r\n01:02:03,000 --> 01:02:03,100\r\nover an hour\r\n\r\n")
        XCTAssertFalse(Subtitles.srt(sample).hasPrefix("\u{FEFF}"))
    }

    func testVTTIsExact() {
        XCTAssertEqual(Subtitles.vtt(sample),
                       "WEBVTT\n\n00:00:00.100 --> 00:00:01.235\n第一行\n第二行\n\n01:02:03.000 --> 01:02:03.100\nover an hour\n\n")
    }

    func testLenientParse() throws {
        // fixtures/subtitles_sample.srt: BOM, CRLF and LF, a missing number, a bad block, an overlap
        let text = String(decoding: try Fixtures.text("subtitles_sample.srt"), as: UTF8.self)
        let p = Subtitles.parseSRT(text)
        XCTAssertEqual(p.cues.map(\.lines), [["你好"], ["no number, dot separator", "second line"], ["overlaps"]])
        XCTAssertEqual(p.cues[0].start, 1)
        XCTAssertEqual(p.cues[0].end, 2.5)
        XCTAssertEqual(p.cues[1].start, 3)
        XCTAssertEqual(p.warnings.count, 2, "\(p.warnings)")
        XCTAssertTrue(p.warnings[0].hasPrefix("line 9:"), p.warnings[0])
        XCTAssertTrue(p.warnings[1].contains("overlap"), p.warnings[1])
    }

    func testRoundTrip() {
        let cues = [SubtitleCue(start: 0.5, end: 1.75, lines: ["一", "二"]), SubtitleCue(start: 61.25, end: 62, lines: ["three"])]
        let back = Subtitles.parseSRT(Subtitles.srt(cues))
        XCTAssertTrue(back.warnings.isEmpty)
        XCTAssertEqual(back.cues, cues)
    }
}
