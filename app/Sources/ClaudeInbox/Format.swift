import Foundation

/// Every user-visible string comes from here. Views may compose these but must
/// never invent a label or a truncation of their own — that is the one rule that
/// keeps the surfaces from drifting apart.
///
/// Ported from `spec/lib/state.ts`. Where behaviour is not obvious, the reason is
/// in the spec's tests; `spec/test/subject.test.ts` is the argument.
enum Format {
    static func truncate(_ value: String, _ max: Int) -> String {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > max, max > 1 else { return s }
        let cut = String(s.prefix(max - 1)).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// One line, no runs of whitespace. Commands arrive with newlines in them.
    static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A row is not a document. Assistant text is written as markdown — `**bold**`,
    /// backticks, bullets, fenced blocks — and none of that renders here.
    static func plainText(_ value: String) -> String {
        var s = value
        // A fenced block is quoted output, not the sentence around it. Left in, a
        // row shows a fragment of whatever the session happened to print.
        s = s.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`{1,3}([^`]*)`{1,3}", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(^|\\s)[*_]([^*_]+)[*_](?=\\s|$)", with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[\\s>#-]+", with: "", options: .regularExpression)
        return oneLine(s)
    }

    /// The last sentence, which in a narration is the current move.
    ///
    /// The model writes "<what just happened>. <what I am doing now>", so the
    /// front of the string is history and the back is the answer. Cutting at a
    /// character count keeps the history and lands mid-word doing it.
    static func lastSentence(_ value: String) -> String {
        let text = oneLine(value)
        guard !text.isEmpty else { return text }

        // A full stop inside «a quote», (an aside) or `code` does not end a
        // sentence, and splitting on it leaves a fragment like `Tests pass…»), а не`.
        let opening: Set<Character> = ["«", "(", "“", "[", "{"]
        let closing: Set<Character> = ["»", ")", "”", "]", "}"]
        let enders: Set<Character> = [".", "!", "?", "…"]

        var starts = [text.startIndex]
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "`" {
                depth = depth > 0 ? depth - 1 : 1
            } else if opening.contains(ch) {
                depth += 1
            } else if closing.contains(ch) {
                depth = max(0, depth - 1)
            } else if depth == 0, enders.contains(ch) {
                var j = text.index(after: i)
                while j < text.endIndex, enders.contains(text[j]) { j = text.index(after: j) }
                if j < text.endIndex, text[j] == " " {
                    starts.append(text.index(after: j))
                    i = j
                }
            }
            i = text.index(after: i)
        }

        var parts: [String] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : text.endIndex
            let part = text[start..<end].trimmingCharacters(in: .whitespaces)
            if !part.isEmpty { parts.append(part) }
        }
        guard parts.count >= 2 else { return parts.first ?? text }

        let last = parts[parts.count - 1]
        // "44 из 44." on its own says nothing; a fragment that short is a result,
        // not an action, so keep the sentence before it as well.
        if last.count >= 16 { return last }
        return (parts[parts.count - 2] + " " + last).trimmingCharacters(in: .whitespaces)
    }

    /// Never a path, never a UUID. Claude Code's own session name wins when there
    /// is one — it is what the person sees in their terminal — then the folder.
    static func projectName(cwd: String?, fallback: String?, name: String?) -> String {
        if let name, !name.isEmpty { return truncate(name, Limits.project) }
        let base = cwd?
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            .split(separator: "/").last.map(String.init)
        return truncate(base ?? fallback ?? "unknown", Limits.project)
    }

    /// Compact and relative: "2m", "1h", "just now". A row has no room for a date.
    static func age(_ ts: Double, now: Date = Date()) -> String {
        let secs = max(0, Int(now.timeIntervalSince1970 - ts))
        if secs < 45 { return "just now" }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 60 { return "\(mins)m" }
        let hours = Int((Double(mins) / 60).rounded())
        if hours < 24 { return "\(hours)h" }
        return "\(Int((Double(hours) / 24).rounded()))d"
    }

    /// "resets in 2h 14m" — a countdown answers "can I keep going", a timestamp doesn't.
    static func resetsIn(_ resetsAt: Double?, now: Date = Date()) -> String? {
        guard let resetsAt, resetsAt > 0 else { return nil }
        let secs = Int((resetsAt - now.timeIntervalSince1970).rounded())
        if secs <= 0 { return "resetting" }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 60 { return "resets in \(mins)m" }
        let hours = mins / 60, rest = mins % 60
        if hours < 24 { return rest > 0 ? "resets in \(hours)h \(rest)m" : "resets in \(hours)h" }
        return "resets in \(Int((Double(hours) / 24).rounded()))d"
    }

    /// The step a session declared, from the slash command that opened the turn:
    /// `/morgan:track fix the icon` -> "track".
    ///
    /// This is the only declaration of intent in the data. Claude Code's todo
    /// lists would be better — an explicit current step and what is left — but not
    /// one of 225 transcripts on this machine contained one, and a board built on
    /// an empty source is a board that is always empty.
    /// What a person actually typed.
    ///
    /// Claude Code delivers system events through UserPromptSubmit too — task
    /// notifications, monitor events, re-wakes. They arrive in the same field as
    /// a person's words and they are not a person's words; showing one as the
    /// subject of a row is showing plumbing.
    static func userPrompt(_ prompt: String?) -> String? {
        guard let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.range(of: "^<[a-zA-Z][a-zA-Z0-9-]*>", options: .regularExpression) != nil { return nil }
        return text
    }

    static func phase(fromPrompt prompt: String?) -> String? {
        guard let trimmed = userPrompt(prompt) else { return nil }
        guard trimmed.hasPrefix("/") else { return nil }
        let word = trimmed.dropFirst().prefix { $0.isLetter || $0.isNumber || ":_-".contains($0) }
        guard let name = word.split(separator: ":").last, !name.isEmpty else { return nil }
        return truncate(name.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression), Limits.ask)
    }

    /// What a blocked session wants, as a lowercase verb phrase.
    static func askPhrase(_ item: PendingItem) -> String {
        let input = item.toolInput
        switch item.kind {
        case "question":
            let questions = input?["questions"]
            if questions?.count ?? 0 > 0 { return truncate("pick one of \(questions!.count)", Limits.ask) }
            return "answer a question"
        case "plan":
            return "approve plan"
        default:
            let tool = item.toolName ?? "a tool"
            if tool == "Bash" {
                guard let cmd = input?["command"]?.stringValue else { return "run a command" }
                return truncate("run " + oneLine(cmd), Limits.ask)
            }
            if ["Write", "Edit", "NotebookEdit"].contains(tool) {
                let file = input?["file_path"]?.stringValue?.split(separator: "/").last.map(String.init)
                return truncate(file.map { "edit \($0)" } ?? "edit a file", Limits.ask)
            }
            if tool.hasPrefix("mcp__") {
                let server = tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst().first
                return truncate("use \(server.map(String.init) ?? "an integration")", Limits.ask)
            }
            return truncate("use \(tool)", Limits.ask)
        }
    }

    /// What a session is about, in the person's own words.
    ///
    /// The state is already in the glyph, so spending the row's only line on
    /// "working" says nothing twice. Order is by how much each source tells you,
    /// and it differs by whether the session is still going: a running one is read
    /// for its current move, an answered one for what it said.
    static func subject(_ s: SessionRecord, max: Int = Limits.subject) -> String {
        func clean(_ value: String?, narration: Bool) -> String? {
            guard let value else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if narration {
                let sentence = plainText(lastSentence(plainText(text)))
                return sentence.isEmpty ? nil : sentence
            }
            // The slash command is shown as the step; repeating it here costs the
            // characters that carry the actual request.
            let stripped = text.replacingOccurrences(
                of: "^\\s*/[a-zA-Z0-9:_-]+\\s*", with: "", options: .regularExpression)
            let body = plainText(stripped)
            return body.isEmpty ? nil : body
        }

        let group = s.state.group
        // Answered and finished are read the same way: the message is the point,
        // and its verdict is at the front.
        let done = group == .finished || group == .answered
        let candidates: [(String?, Bool)] = done
            ? [(s.lastMessage, false), (s.saying, true), (s.title, false), (userPrompt(s.lastPrompt), false)]
            // The title names the work; the newest prompt is usually an aside.
            : [(s.saying, true), (s.title, false), (userPrompt(s.lastPrompt), false), (s.activity.first, false)]

        for (candidate, narration) in candidates {
            if let text = clean(candidate, narration: narration) { return truncate(text, max) }
        }
        // The step is thin, but it is a fact about the work. "working" beside a
        // glyph that already means working is a row spent on nothing.
        if let phase = s.phase { return truncate(phase, max) }
        return s.state.label.lowercased()
    }
}
