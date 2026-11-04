import Foundation

/// One recognised word (or character, for Chinese) with its time in the
/// source's timeline, seconds.
public struct SubtitleToken: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public let confidence: Float?

    public init(text: String, start: Double, end: Double, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// One subtitle: up to two lines on screen from `start` to `end` (seconds).
public struct SubtitleCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var lines: [String]

    public var text: String { lines.joined(separator: "\n") }

    public init(start: Double, end: Double, lines: [String]) {
        self.start = start
        self.end = end
        self.lines = lines
    }
}

/// Chinese, Japanese and Korean count characters and join without spaces;
/// everything else counts characters including spaces.
public enum SubtitleScript: Sendable {
    case cjk, latin

    public init(language identifier: String) {
        let l = identifier.lowercased()
        self = ["zh", "ja", "ko", "yue"].contains { l.hasPrefix($0) } ? .cjk : .latin
    }
}

/// Splitting recognised tokens into cues, and SRT / WebVTT in and out
/// (CLAUDE.md 字幕; tune the parameters there first).
public enum Subtitles {
    public static let pauseSeconds = 0.6
    public static let maxSeconds = 6.0
    public static let minSeconds = 0.8
    public static let holdSeconds = 0.2
    public static let cutSnapSeconds = 0.3
    public static let cutMinGap = 0.1
    public static let gapFrames = 2.0

    /// Lines per cue: Chinese, Japanese and Korean one (the usual style; the
    /// recogniser's Chinese has no pauses between characters, so two-line cues ran
    /// to the 6 s limit, 2026-11-04), others two.
    public static func maxLines(_ script: SubtitleScript) -> Int { script == .cjk ? 1 : 2 }

    /// Characters per line: (original / 16:9, 9:16).
    public static func lineLimit(_ script: SubtitleScript, vertical: Bool) -> Int {
        switch script {
        case .cjk: vertical ? 12 : 16
        case .latin: vertical ? 32 : 42
        }
    }

    static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", ".", "…"]
    static let clauseEnds: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]

    // MARK: tokens -> cues

    /// `cuts`: shot start times after the first (seconds); `frameSeconds`: one frame.
    public static func cues(tokens: [SubtitleToken], cuts: [Double], frameSeconds: Double,
                            script: SubtitleScript, vertical: Bool) -> [SubtitleCue] {
        let limit = lineLimit(script, vertical: vertical)
        let words = attachPunctuation(tokens.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        var groups: [[SubtitleToken]] = [], current: [SubtitleToken] = [], currentFirst = 0
        let cutBefore = cutBreaks(words, cuts: cuts)
        let wordStart = wordStarts(words, script)

        func length(_ ts: [SubtitleToken]) -> Int { join(ts, script).count }

        for (index, token) in words.enumerated() {
            guard let last = current.last, let first = current.first else { current = [token]; currentFirst = index; continue }
            let endsSentence = last.text.trimmingCharacters(in: .whitespaces).last.map(sentenceEnds.contains) ?? false
            let cut = cutBefore.contains(index)
            if token.start - last.end >= pauseSeconds || endsSentence || cut {
                groups.append(current)
                current = [token]
                currentFirst = index
            } else if length(current + [token]) > maxLines(script) * limit || token.end - first.start > maxSeconds {
                // too long: break after the last clause mark, else at the best boundary (pause, word)
                let split = current.dropLast().lastIndex(where: { $0.text.trimmingCharacters(in: .whitespaces).last.map(clauseEnds.contains) ?? false })
                    ?? bestBreak(current + [token], wordStart: Array(wordStart[currentFirst...index]))
                groups.append(Array(current[...split]))
                current = Array(current[(split + 1)...]) + [token]
                currentFirst += split + 1
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { groups.append(current) }

        let gap = gapFrames * frameSeconds
        var cues = groups.map { g in
            SubtitleCue(start: g.first!.start, end: max(g.last!.end + holdSeconds, g.first!.start + minSeconds),
                        lines: lines(g, script, limit: limit))
        }
        for i in cues.indices.dropLast() {                       // never run into the next cue
            cues[i].end = max(min(cues[i].end, cues[i + 1].start - gap), cues[i].start + frameSeconds)
        }
        return cues
    }

    /// The recogniser returns punctuation as its own token whose time spans the
    /// pause after the word (zh: "，" 1.26-1.68 s, measured 2026-11-04), which would
    /// hide the pause from the splitter. Punctuation joins the word before it and
    /// takes no time of its own.
    static func attachPunctuation(_ tokens: [SubtitleToken]) -> [SubtitleToken] {
        var out: [SubtitleToken] = []
        for t in tokens {
            let bare = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = out.last, !bare.isEmpty, bare.allSatisfy({ $0.isPunctuation || $0.isSymbol }) {
                out[out.count - 1] = SubtitleToken(text: last.text + bare, start: last.start, end: last.end, confidence: last.confidence)
            } else {
                out.append(t)
            }
        }
        return out
    }

    /// The index to break after when `ts` (the cue plus the token that overflowed it)
    /// is too long: among the boundaries before the overflowing token, the widest
    /// pause; with no pause, the last word boundary; else just before the overflow.
    static func bestBreak(_ ts: [SubtitleToken], wordStart: [Bool]) -> Int {
        let last = ts.count - 2                                      // break after this at the latest
        guard last > 0 else { return 0 }
        var best: (index: Int, gap: Double)?
        for i in max(1, ts.count - 6)...(ts.count - 1) {             // break between i-1 and i
            let gap = ts[i].start - ts[i - 1].end
            if gap > 0.02, gap >= (best?.gap ?? 0) { best = (i - 1, gap) }
        }
        if let best { return min(best.index, last) }
        if let w = (1...(ts.count - 1)).reversed().first(where: { wordStart[$0] }) { return min(w - 1, last) }
        return last
    }

    /// Which tokens start a word: CJK by the system's word segmentation (the
    /// recogniser returns Chinese one character per token, 2026-11-04), others always.
    static func wordStarts(_ ts: [SubtitleToken], _ script: SubtitleScript) -> [Bool] {
        guard script == .cjk, !ts.isEmpty else { return ts.map { _ in true } }
        let pieces = ts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = pieces.joined() as NSString
        var starts = Set<Int>()
        let tokenizer = CFStringTokenizerCreate(nil, text, CFRange(location: 0, length: text.length),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "zh_CN") as CFLocale)
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            starts.insert(CFStringTokenizerGetCurrentTokenRange(tokenizer).location)
        }
        var offset = 0
        return pieces.map { piece in
            defer { offset += (piece as NSString).length }
            return starts.contains(offset) || offset == 0
        }
    }

    /// Where a shot cut splits a cue: at most once per cut, at the boundary within
    /// ±`cutSnapSeconds` of it with the longest pause (punctuation counts as a pause),
    /// and only if that pause is at least `cutMinGap`. In continuous speech the cue
    /// runs across the cut rather than split a word: Chinese comes back one character
    /// per token, so every gap is a "word boundary" (2026-11-04: a cut inside 篮球馆
    /// cut "圆" and "球" into 40 ms cues of their own).
    static func cutBreaks(_ words: [SubtitleToken], cuts: [Double]) -> Set<Int> {
        var breaks = Set<Int>()
        for c in cuts {
            var best: (index: Int, gap: Double)?
            for i in words.indices.dropFirst() {
                let boundary = (words[i - 1].end + words[i].start) / 2
                guard abs(boundary - c) <= cutSnapSeconds else { continue }
                let punctuated = words[i - 1].text.trimmingCharacters(in: .whitespaces).last.map {
                    sentenceEnds.contains($0) || clauseEnds.contains($0)
                } ?? false
                let gap = max(words[i].start - words[i - 1].end, punctuated ? cutMinGap : 0)
                if gap > (best?.gap ?? -1) { best = (i, gap) }
            }
            if let best, best.gap >= cutMinGap { breaks.insert(best.index) }
        }
        return breaks
    }

    static func join(_ ts: [SubtitleToken], _ script: SubtitleScript) -> String {
        switch script {
        case .cjk:
            return ts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        case .latin:
            let raw = ts.map(\.text).joined()
            return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    /// One line if it fits, else two, split at the token boundary nearest the
    /// middle (a clause mark wins if one is near).
    static func lines(_ ts: [SubtitleToken], _ script: SubtitleScript, limit: Int) -> [String] {
        let whole = join(ts, script)
        guard whole.count > limit, ts.count > 1, maxLines(script) > 1 else { return [whole] }
        var best = 1, bestScore = Int.max
        for k in 1..<ts.count {
            let a = join(Array(ts[..<k]), script).count, b = join(Array(ts[k...]), script).count
            var score = abs(a - b) + (max(a, b) > limit ? 1000 : 0)
            if ts[k - 1].text.trimmingCharacters(in: .whitespaces).last.map(clauseEnds.contains) ?? false { score -= 4 }
            if score < bestScore { bestScore = score; best = k }
        }
        return [join(Array(ts[..<best]), script), join(Array(ts[best...]), script)]
    }

    /// The cue on screen at `seconds`, if any (cues sorted by start).
    public static func cue(at seconds: Double, in cues: [SubtitleCue]) -> Int? {
        var lo = 0, hi = cues.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= seconds { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let k = found, seconds < cues[k].end else { return nil }
        return k
    }

    // MARK: SRT / WebVTT out

    /// Start rounded down, end rounded up to the millisecond, so a cue never
    /// starts late or ends early. (Rounded to the microsecond first: 0.1 s is
    /// not exactly 100 ms in binary.)
    static func milliseconds(_ seconds: Double, roundUp: Bool) -> Int {
        let us = (max(seconds, 0) * 1_000_000).rounded()
        return Int(roundUp ? (us / 1000).rounded(.up) : (us / 1000).rounded(.down))
    }

    static func stamp(_ ms: Int, separator: Character) -> String {
        String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, String(separator), ms % 1000)
    }

    /// UTF-8 without BOM, CRLF (CLAUDE.md 字幕).
    public static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\r\n\(stamp(milliseconds(c.start, roundUp: false), separator: ",")) --> "
                + "\(stamp(milliseconds(c.end, roundUp: true), separator: ","))\r\n"
                + c.lines.joined(separator: "\r\n") + "\r\n\r\n"
        }.joined()
    }

    public static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(stamp(milliseconds(c.start, roundUp: false), separator: ".")) --> "
                + "\(stamp(milliseconds(c.end, roundUp: true), separator: "."))\n" + c.lines.joined(separator: "\n") + "\n\n"
        }.joined()
    }

    // MARK: SRT in

    public struct Parsed: Sendable {
        public let cues: [SubtitleCue]
        public let warnings: [String]
    }

    /// Lenient: LF or CRLF, a BOM, missing or skipped numbers, `,` or `.` before
    /// the milliseconds. A block without a valid time line is reported with its
    /// line number and skipped; overlapping cues are kept and reported.
    public static func parseSRT(_ text: String) -> Parsed {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.components(separatedBy: "\n")
        var cues: [SubtitleCue] = [], warnings: [String] = []
        var block: [(Int, String)] = []

        func flush() {
            defer { block = [] }
            guard !block.isEmpty else { return }
            var rest = block
            if rest.count > 1, Int(rest[0].1.trimmingCharacters(in: .whitespaces)) != nil, parseTimes(rest[1].1) != nil { rest.removeFirst() }
            guard let (start, end) = parseTimes(rest[0].1) else {
                warnings.append("line \(block[0].0): no time line (\"\(block[0].1.prefix(40))\"); skipped")
                return
            }
            let textLines = rest.dropFirst().map { $0.1 }
            guard end > start else {
                warnings.append("line \(rest[0].0): end is not after start; skipped")
                return
            }
            cues.append(SubtitleCue(start: start, end: end, lines: textLines))
        }
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append((i + 1, line)) }
        }
        flush()
        for (a, b) in zip(cues, cues.dropFirst()) where b.start < a.end {
            warnings.append(String(format: "cues overlap at %.3f s (kept as they are)", b.start))
        }
        return Parsed(cues: cues, warnings: warnings)
    }

    static func parseTimes(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let a = parseStamp(parts[0]), let b = parseStamp(parts[1]) else { return nil }
        return (a, b)
    }

    static func parseStamp(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let hms = t.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(hms.count) else { return nil }
        let nums = hms.map { Double($0) }
        guard nums.allSatisfy({ $0 != nil }) else { return nil }
        let v = nums.map { $0! }
        return v.count == 3 ? v[0] * 3600 + v[1] * 60 + v[2] : v[0] * 60 + v[1]
    }
}
