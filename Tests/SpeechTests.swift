import AutoGradeCore
import AVFoundation
import XCTest

/// On-device recognition (CLAUDE.md 字幕) on speech synthesised by `say` at test
/// time: no fixture, so it never goes stale. Skips when the OS is older than 26
/// or the language's model is not installed (report the skip).
final class SpeechTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    private func synthesise(_ text: String, voice: String) throws -> URL {
        let out = dir.appendingPathComponent("\(UUID().uuidString).aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", out.path, text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("say -v \(voice) failed") }
        return out
    }

    /// Character error rate after dropping punctuation, spaces and case.
    static func cer(_ got: String, _ want: String) -> Double {
        func norm(_ s: String) -> [Character] { Array(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let a = norm(got), b = norm(want)
        var d = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = d[0]
            d[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let t = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = t
            }
        }
        return Double(a.isEmpty ? b.count : d[b.count]) / Double(max(b.count, 1))
    }

    /// `maxCER`: Mandarin 0.10. English 0.15: the synthetic voice is heard as "round"
    /// and "top" for "brown" and "dog" (CER 0.098 measured 2026-11-04, so 0.10 had no margin).
    private func check(_ language: String, voice: String, text: String, maxCER: Double) throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        guard let locale = try Transcriber.locale(for: language) else { throw XCTSkip("\(language) not supported") }
        // The model state is per app (each process reserves its own languages), so the test
        // runner reads "needs download" even after the CLI installed the shared model. Try it.
        let state = try Transcriber.modelState(locale)
        guard state != .unsupported else { throw XCTSkip("\(language) unsupported") }
        print("speech \(language): model state for this process: \(state.rawValue)")
        let audio = try synthesise(text, voice: voice)
        let duration = AVURLAsset(url: audio).duration.seconds
        let start = CFAbsoluteTimeGetCurrent()
        let tokens: [SubtitleToken]
        do {
            tokens = try Transcriber.transcribe(audio, locale: locale)
        } catch {
            throw XCTSkip("\(language): recognition failed (\(error)); install with autograde --download-speech-model \(language)")
        }
        let seconds = CFAbsoluteTimeGetCurrent() - start
        let joined = tokens.map(\.text).joined()
        let rate = Self.cer(joined, text)
        print("speech \(language): \(tokens.count) tokens in \(String(format: "%.2f", seconds)) s for \(String(format: "%.2f", duration)) s audio; "
              + "CER \(String(format: "%.3f", rate)); \"\(joined)\"")
        print("speech \(language) tokens: " + tokens.prefix(12).map { String(format: "[%@ %.2f-%.2f]", $0.text, $0.start, $0.end) }.joined(separator: " "))
        XCTAssertLessThanOrEqual(rate, maxCER)
        XCTAssertFalse(tokens.isEmpty)
        for (a, b) in zip(tokens, tokens.dropFirst()) { XCTAssertLessThanOrEqual(a.start, b.start, "starts in order") }
        for t in tokens {
            XCTAssertLessThanOrEqual(t.start, t.end)
            XCTAssertGreaterThanOrEqual(t.start, -0.01)
            XCTAssertLessThanOrEqual(t.end, duration + 0.05)
        }
    }

    func testMandarin() throws {
        try check("zh-CN", voice: "Flo (中文（中国大陆）)", text: "今天天气很好，我们一起去公园散步，然后回家吃晚饭。", maxCER: 0.10)
    }

    func testEnglish() throws {
        try check("en-US", voice: "Flo (英语（美国）)", text: "The quick brown fox jumps over the lazy dog near the river bank.", maxCER: 0.15)
    }
}
