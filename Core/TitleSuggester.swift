import Foundation

/// What a title suggestion is based on (CLAUDE.md 封面 / 云端候选): text only,
/// never pictures, file names or paths.
public struct TitleRequest: Sendable, Equatable {
    public var topic: String?
    public var transcript: String?
    /// Characters per title (letters and digits count one each): 16 wide, 12 tall.
    public var limit: Int
    /// Candidates already offered in this session; "another batch" asks for new ones.
    public var exclude: [String]

    public init(topic: String? = nil, transcript: String? = nil, limit: Int = 16, exclude: [String] = []) {
        self.topic = topic
        self.transcript = transcript
        self.limit = limit
        self.exclude = exclude
    }

    var cleanTopic: String? { topic.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
    var cleanTranscript: String? {
        transcript.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// From subtitles: the cues' text in order, one cue per line.
    public init(topic: String?, cues: [SubtitleCue], aspects: [CoverAspect], sourceWidth: Int, sourceHeight: Int,
                exclude: [String] = []) {
        let text = cues.map { $0.lines.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n")
        self.init(topic: topic, transcript: text.isEmpty ? nil : text,
                  limit: TitleRequest.limit(for: aspects, sourceWidth: sourceWidth, sourceHeight: sourceHeight), exclude: exclude)
    }

    /// 12 characters when any cover is taller than wide (3:4, or the original
    /// frame of a vertical clip), else 16 (CLAUDE.md 封面 / 输出约束).
    public static func limit(for aspects: [CoverAspect], sourceWidth: Int, sourceHeight: Int) -> Int {
        aspects.contains {
            let (w, h) = $0.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
            return h > w
        } ? 12 : 16
    }

    /// Nothing to go on but a topic: candidates come out nearly alike (probe round 2).
    public var isThin: Bool { cleanTranscript == nil }
    public var isEmpty: Bool { cleanTopic == nil && cleanTranscript == nil }
}

/// Sends one HTTP request; replaced by a fake in tests so they never touch the network.
public protocol TitleTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

public struct URLSessionTitleTransport: TitleTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum TitleSuggestionError: Error, Equatable, CustomStringConvertible {
    case noInput
    case http(status: Int, message: String)
    case badResponse
    case noUsableTitles
    case network(String)

    /// Never contains the key: only a status code and the service's short message.
    public var description: String {
        switch self {
        case .noInput: "nothing to base titles on: add a topic or subtitles"
        case .http(let status, let message):
            switch status {
            case 401: "the DeepSeek key was refused (401)"
            case 402: "the DeepSeek account has no balance left (402)"
            case 429: "DeepSeek is rate-limiting requests (429); try again shortly"
            default: "DeepSeek answered \(status)" + (message.isEmpty ? "" : ": \(message)")
            }
        case .badResponse: "DeepSeek did not return the expected json, twice"
        case .noUsableTitles: "no usable candidates (all too long, empty or repeated)"
        case .network(let why): "could not reach DeepSeek: \(why)"
        }
    }
}

/// Title candidates from DeepSeek (CLAUDE.md 封面 / 云端候选). Off unless the
/// owner turned it on and gave a key; the caller decides that, this only asks.
public enum TitleSuggester {
    // CLAUDE.md 封面 / 云端候选 — change the rules there first.
    public static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    public static let model = "deepseek-flash"
    public static let timeout: TimeInterval = 15
    public static let maxTokens = 300
    public static let temperature = 1.0
    public static let transcriptLimit = 2000
    public static let count = 5

    /// Round 2's instructions (probe `out/cover/llm/`): condense, five angles, keep the meaning.
    static func instructions(limit: Int) -> String {
        """
        你是短视频封面标题编辑。根据输入写 \(count) 个封面标题候选。
        1. 提炼和概括，写成让人想点开的封面标题，可以带情绪或悬念；不要直接照抄口播里的原句。
        2. 只能使用输入里有的事实，不新增人名、地名、数字、品牌或事件；不改变原文的意思，不把词语换成另一种理解。
        3. \(count) 个标题的角度要不同：一个概括全片，一个突出具体细节，一个突出感受，一个用数字或对比（仅当输入里有数字），一个用提问或悬念。
        4. 简体中文，每条不超过 \(limit) 个字（英文字母和数字每个算一个字），不加引号，结尾不加标点。
        只输出 json，格式：{"titles": ["标题一", "标题二", "标题三", "标题四", "标题五"]}
        """
    }

    static func userPrompt(_ r: TitleRequest) -> String {
        var parts: [String] = []
        if let t = r.cleanTopic { parts.append("主题：\(t)") }
        if let s = r.cleanTranscript { parts.append("视频口播：\(String(s.prefix(transcriptLimit)))") }
        if !r.exclude.isEmpty { parts.append("下面这些已经给过，换不同的说法：\(r.exclude.joined(separator: "；"))") }
        return parts.joined(separator: "\n") + "\n请给出 \(count) 个封面标题候选。"
    }

    /// The HTTP request. The key goes in the Authorization header and nowhere else.
    public static func request(_ r: TitleRequest, key: String) -> URLRequest {
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": instructions(limit: r.limit)],
                         ["role": "user", "content": userPrompt(r)]],
            "thinking": ["type": "disabled"],          // on by default; off is faster, and temperature only works off
            "response_format": ["type": "json_object"],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Titles in a response body, or nil when the content is blank or not the json asked for.
    static func titles(in data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let titles = inner["titles"] as? [String] else { return nil }
        return titles
    }

    /// Characters as the prompt counts them: everything but whitespace.
    public static func length(_ s: String) -> Int { s.filter { !$0.isWhitespace }.count }

    /// Trim; drop empty, over-long (never cut to fit), repeated and already offered titles.
    public static func filter(_ titles: [String], limit: Int, exclude: [String]) -> [String] {
        var seen = Set(exclude), out: [String] = []
        for t in titles {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, length(clean) <= limit, !seen.contains(clean) else { continue }
            seen.insert(clean)
            out.append(clean)
        }
        return out
    }

    /// Ask once (one retry when the content is blank or not json; none on HTTP errors).
    public static func suggest(_ r: TitleRequest, key: String,
                               transport: TitleTransport = URLSessionTitleTransport()) async throws -> [String] {
        guard !r.isEmpty else { throw TitleSuggestionError.noInput }
        let req = request(r, key: key)
        for _ in 0..<2 {
            let reply: (data: Data, status: Int)
            do {
                reply = try await transport.send(req)
            } catch {
                throw TitleSuggestionError.network((error as NSError).localizedDescription)
            }
            guard reply.status == 200 else { throw TitleSuggestionError.http(status: reply.status, message: serviceMessage(reply.data, key: key)) }
            guard let raw = titles(in: reply.data) else { continue }   // blank or not json: retry once
            let kept = filter(raw, limit: r.limit, exclude: r.exclude)
            if kept.isEmpty { throw TitleSuggestionError.noUsableTitles }
            return kept
        }
        throw TitleSuggestionError.badResponse
    }

    /// The service's own short error message (`error.message`), at most 120 characters,
    /// with anything key-like removed: some services echo a masked key ("sk-ab***yz") on 401.
    static func serviceMessage(_ data: Data, key: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any], var message = error["message"] as? String else { return "" }
        if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "[redacted]") }
        message = message.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            return w.contains("sk-") || w.contains("***") || (!key.isEmpty && key.count >= 8 && w.contains(String(key.suffix(4))))
                ? "[redacted]" : w
        }.joined(separator: " ")
        return String(message.prefix(120))
    }
}
