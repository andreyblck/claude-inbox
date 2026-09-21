import Foundation

/// Reading what a session is about out of its transcript.
///
/// Transcripts reach hundreds of megabytes, so only the tail is ever read.
/// Ported from `spec/lib/inbox.ts`.
enum Transcript {
    struct Summary: Sendable, Equatable {
        var title: String?
        var doing: String?
        /// The model's own sentence about what it is doing, written just before it
        /// acts. Nothing we could generate beats it: it is already there, already
        /// in the person's language, and costs neither a token nor a millisecond.
        var saying: String?
        /// What was last asked. The bridge captures this on UserPromptSubmit, but
        /// only for sessions started after it was installed — the transcript has
        /// it for every session, in the same tail we are already reading.
        var prompt: String?
        /// The newest tool call, when nothing has answered it yet: the thing a
        /// blocked session is stopped on.
        var asking: String?
    }

    /// One Read result can fill 64 KB on its own, and then the tail holds no
    /// sentence at all — which is how a row ends up reading `running sed -n 70,78p`
    /// instead of what the session is up to. The cache pays for this.
    private static let summaryTail = 256 * 1024
    private static let narrationTail = 192 * 1024
    private static let cacheTTL: TimeInterval = 20

    private struct Cached { var at: Date; var summary: Summary }
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let cacheLock = NSLock()

    static func readTail(_ path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `Bash · npm test` -> "running npm test". A row is read, not parsed.
    private static func describe(tool: String, input: JSONValue?) -> String {
        func str(_ key: String) -> String? { input?[key]?.stringValue }
        func file() -> String? { str("file_path")?.split(separator: "/").last.map(String.init) }

        switch tool {
        case "Bash":
            // The model writes a description beside every command, and it is the
            // sentence the command only implies.
            if let said = str("description")?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
                return Format.oneLine(said)
            }
            return "running " + (str("command").map(gist) ?? "a command")
        case "Read":
            return "reading " + (file() ?? "a file")
        case "Edit", "Write", "NotebookEdit":
            return "editing " + (file() ?? "a file")
        case "Grep", "Glob":
            return "searching for " + Format.oneLine(str("pattern") ?? "something")
        case "WebSearch", "WebFetch":
            return "looking something up"
        case "Task", "Agent":
            return "running " + Format.oneLine(str("description") ?? "an agent")
        default:
            if tool.hasPrefix("mcp__") {
                let server = tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst().first
                return "using " + (server.map(String.init) ?? "an integration")
            }
            return "using " + tool
        }
    }

    /// The interesting half of a shell command.
    ///
    /// Commands arrive as `cd /long/absolute/path && npm test`, and the path is
    /// the part nobody needs — it is the project, which the row already says.
    private static func gist(_ command: String) -> String {
        // A heredoc is a whole script on one line; the interpreter is the only
        // part of it that reads as anything.
        let head = command.replacingOccurrences(
            of: "<<[-~]?['\"]?\\w[\\s\\S]*$", with: "", options: .regularExpression)
        let parts = Format.oneLine(head)
            .components(separatedBy: CharacterSet(charactersIn: ";"))
            .flatMap { $0.components(separatedBy: "&&") }
            .flatMap { $0.components(separatedBy: "||") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in
                !part.isEmpty
                    && !part.hasPrefix("cd ")
                    && !part.hasPrefix("export ")
                    && !part.hasPrefix("source ")
            }
        return parts.first ?? Format.oneLine(head.isEmpty ? command : head)
    }

    /// What a session is about, and what it is doing, from one read of the tail.
    static func summary(of path: String?) -> Summary {
        guard let path else { return Summary() }
        cacheLock.lock()
        if let hit = cache[path], Date().timeIntervalSince(hit.at) < cacheTTL {
            cacheLock.unlock()
            return hit.summary
        }
        cacheLock.unlock()

        var summary = Summary()
        var answered = false
        if let buf = readTail(path, bytes: summaryTail) {
            for line in buf.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                if summary.title != nil, summary.doing != nil, summary.saying != nil, summary.prompt != nil { break }
                guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { continue }
                // Truncated first line of the window is expected, so a failure to
                // parse is never an error here.
                guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let type = row["type"] as? String
                if summary.title == nil, type == "ai-title", let title = row["aiTitle"] as? String {
                    summary.title = title
                }
                if summary.prompt == nil, type == "last-prompt", let prompt = row["lastPrompt"] as? String {
                    summary.prompt = prompt
                }
                guard let message = row["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]]
                else { continue }
                for block in content.reversed() {
                    let kind = block["type"] as? String
                    if summary.doing == nil, kind == "tool_result" { answered = true }
                    if summary.doing == nil, kind == "tool_use", let name = block["name"] as? String {
                        let input = (block["input"] as? [String: Any]).flatMap(jsonValue)
                        summary.doing = describe(tool: name, input: input)
                        if !answered { summary.asking = summary.doing }
                    }
                    if summary.saying == nil, type == "assistant", kind == "text",
                       let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        summary.saying = Format.oneLine(text)
                    }
                }
            }
        }

        cacheLock.lock()
        cache[path] = Cached(at: Date(), summary: summary)
        cacheLock.unlock()
        return summary
    }

    /// The text of a user row, whichever of the two shapes it was written in.
    private static func userText(_ row: [String: Any]) -> String? {
        guard row["type"] as? String == "user", let message = row["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func row(in data: Data, around hit: Range<Data.Index>) -> (row: [String: Any]?, start: Data.Index, stop: Data.Index) {
        let start = data[..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
        let stop = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
        return (try? JSONSerialization.jsonObject(with: data[start..<stop]) as? [String: Any], start, stop)
    }

    /// What the person asked for over the life of a session: the first two things
    /// and the last two, which is where a piece of work gets named and renamed.
    ///
    /// Slash commands are read from their own rows. A bare one never reaches
    /// `last-prompt`, and leaving it out named a session opened with
    /// `/sky-verify-mine` after whatever it happened to be running: "Controller
    /// tests".
    static func prompts(of path: String?) -> [String] {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        else { return [] }
        var found: [(at: Data.Index, text: String)] = []
        for marker in ["\"type\":\"last-prompt\"", "<command-name>"] {
            let needle = Data(marker.utf8)
            var from = data.startIndex
            while let hit = data.range(of: needle, in: from..<data.endIndex) {
                let (row, start, stop) = row(in: data, around: hit)
                if let row {
                    let text = marker.hasPrefix("<")
                        ? userText(row).flatMap(Format.command(in:))
                        : Format.userPrompt(row["lastPrompt"] as? String)
                    if let text { found.append((start, text)) }
                }
                from = stop
            }
        }
        var all: [String] = []
        for item in found.sorted(by: { $0.at < $1.at }) where all.last != item.text { all.append(item.text) }
        return all.count <= 4 ? all : Array(all.prefix(2) + all.suffix(2))
    }

    nonisolated(unsafe) private static var commandCache: [String: String?] = [:]

    /// The command a session was opened with, for a record that lost it. Read
    /// once: a newer one reaches us through the bridge, which now keeps the step.
    static func command(of path: String?) -> String? {
        guard let path else { return nil }
        cacheLock.lock()
        if let hit = commandCache[path] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        var found: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            let needle = Data("<command-name>".utf8)
            var end = data.endIndex
            while found == nil, let hit = data.range(of: needle, options: .backwards, in: data.startIndex..<end) {
                let (row, start, _) = row(in: data, around: hit)
                found = row.flatMap(userText).flatMap(Format.command(in:))
                end = start
            }
        }

        cacheLock.lock()
        commandCache[path] = found
        cacheLock.unlock()
        return found
    }

    nonisolated(unsafe) private static var issueCache: [String: String?] = [:]

    /// The issue a session was given, for a record that lost it.
    ///
    /// The link is in the first prompt and a follow-up never repeats it, so a
    /// session older than the bridge's `issue` field has nothing left in its
    /// record. The whole file is read, once, and mapped rather than loaded: only
    /// `last-prompt` rows count, because a tool result names other issues all day
    /// and none of them is this session.
    static func issue(of path: String?) -> String? {
        guard let path else { return nil }
        cacheLock.lock()
        if let hit = issueCache[path] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        var found: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            let marker = Data("\"type\":\"last-prompt\"".utf8)
            var end = data.endIndex
            while found == nil, let hit = data.range(of: marker, options: .backwards, in: data.startIndex..<end) {
                let start = data[..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
                let stop = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
                if let row = try? JSONSerialization.jsonObject(with: data[start..<stop]) as? [String: Any] {
                    found = Format.issue(fromPrompt: row["lastPrompt"] as? String)
                }
                end = start
            }
        }

        cacheLock.lock()
        issueCache[path] = found
        cacheLock.unlock()
        return found
    }

    /// Everything the session has said since the last thing you said to it.
    ///
    /// `lastMessage` only exists once a turn has ended, so a session still working
    /// showed a single paragraph — and you went to the terminal to read the rest,
    /// which is the round trip this app exists to remove.
    static func narration(of path: String?) -> String? {
        guard let path, let buf = readTail(path, bytes: narrationTail) else { return nil }
        var said: [String] = []
        for line in buf.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = row["type"] as? String
            let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]]

            if type == "assistant", let content {
                for block in content.reversed() where block["type"] as? String == "text" {
                    if let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        said.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                continue
            }
            guard type == "user" else { continue }
            // A tool result is also a "user" row. Treating it as the boundary
            // would cut the turn at the first command it ran.
            let isToolResult = content?.contains { $0["type"] as? String == "tool_result" } ?? false
            if !isToolResult { break }
        }
        return said.isEmpty ? nil : said.reversed().joined(separator: "\n\n")
    }

    /// The last few things a session did, newest first.
    static func activity(of path: String?, max: Int = 6) -> [String] {
        guard let path, let buf = readTail(path, bytes: narrationTail) else { return [] }
        var tools: [String] = []
        for line in buf.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if tools.count >= max { break }
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            for block in content.reversed() where block["type"] as? String == "tool_use" {
                if tools.count >= max { break }
                guard let name = block["name"] as? String else { continue }
                let input = (block["input"] as? [String: Any]).flatMap(jsonValue)
                tools.append(describe(tool: name, input: input))
            }
        }
        return tools
    }

    private static func jsonValue(_ dict: [String: Any]) -> JSONValue? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
