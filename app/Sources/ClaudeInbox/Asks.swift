import Foundation

/// Whether a turn ended by asking the person for something.
///
/// `Stop` says a turn ended and nothing else. A session standing there with five
/// decisions it needs — "Нужно твоё решение (без него «полный» не наступит)" —
/// looks exactly like one that is done, and was filed under Answered. Only the
/// message knows, so the `claude` on the machine reads it: once per message, off
/// to the side, never on the way to a redraw. Until the reading lands the row
/// stays where `Stop` put it.
enum Asks {
    struct Reading: Codable, Sendable {
        var hash: String
        var needsYou: Bool
        var line: String
        /// Optional so that a reading cached before replies existed still decodes.
        var replies: [String]?
        var at: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var entries: [String: Reading] = [:]
    nonisolated(unsafe) private static var inFlight: Set<String> = []
    nonisolated(unsafe) private static var refused: [String: String] = [:]
    private static let keepFor: TimeInterval = 3 * 24 * 3600
    private static let queue = DispatchQueue(label: "claude-inbox.asks", qos: .userInitiated)

    private static var file: String {
        (Inbox.directory as NSString).appendingPathComponent("asks.json")
    }

    private static func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: file),
              let saved = try? JSONDecoder().decode([String: Reading].self, from: data)
        else { return }
        entries = saved
    }

    /// Stable across launches, which `hashValue` is not.
    private static func fingerprint(_ text: String) -> String {
        var h: UInt64 = 5381
        for byte in text.utf8 { h = (h &* 33) ^ UInt64(byte) }
        return String(h, radix: 36) + "-" + String(text.utf8.count)
    }

    /// The reading of this exact message, if there is one.
    static func cached(_ sessionId: String, message: String) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        guard let hit = entries[sessionId], hit.hash == fingerprint(message) else { return nil }
        return hit
    }

    static func want(_ sessionId: String, message: String, then done: @escaping @Sendable () -> Void) {
        let hash = fingerprint(message)
        lock.lock()
        loadLocked()
        guard entries[sessionId]?.hash != hash, refused[sessionId] != hash, !inFlight.contains(sessionId) else {
            lock.unlock()
            return
        }
        inFlight.insert(sessionId)
        lock.unlock()

        queue.async {
            let reading = read(message).map {
                Reading(hash: hash, needsYou: $0.needsYou, line: $0.line, replies: $0.replies, at: Date().timeIntervalSince1970)
            }
            lock.lock()
            inFlight.remove(sessionId)
            if let reading {
                entries[sessionId] = reading
                let cutoff = Date().timeIntervalSince1970 - keepFor
                entries = entries.filter { $0.value.at > cutoff }
                if let data = try? JSONEncoder().encode(entries) {
                    try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
                }
            } else {
                // One try per message: a reply that could not be read once will
                // not read better ten seconds later.
                refused[sessionId] = hash
            }
            lock.unlock()
            if reading != nil { done() }
        }
    }

    private static func read(_ message: String) -> (needsYou: Bool, line: String, replies: [String])? {
        // What a session needs is said at the end; what it is about, at the start.
        let text = message.count <= 3200 ? message : String(message.prefix(600)) + "\n[…]\n" + String(message.suffix(2600))
        let prompt = """
            Below is the last message a Claude Code working session wrote to its \
            person, after which its turn ended.

            Is the session waiting for the PERSON — a decision, an answer, a choice or \
            an approval without which the work does not go on? Say YES only when the \
            message turns to the person with a question, a choice or a request to \
            approve. Waiting for CI, for background agents, monitors or timers is NOT \
            waiting for the person, and neither is waiting for a reviewer, a review \
            agent or a report when the message says what the session will do next once \
            it arrives: it will wake and carry on by itself. A polite "let me know if \
            you need anything" at the end is not either.

            Reply with these lines and nothing else:
            1) YES or NO
            2) one line, at most 90 characters, no markdown, written in the language \
            the message's own sentences are written in (code, identifiers and English \
            terms inside a Russian message do not make it English). If YES: what exactly is needed from the person, \
            leading with the substance. If NO: the main thing that happened, or where \
            things stand.
            3) ONLY if YES: `REPLIES: a | b | c` — up to three short answers the \
            person is likely to give, in the same language as line 2, as they would type them \
            (at most 40 characters each; the first is the plain go-ahead; no gendered \
            forms of "I").

            The message:
            \(text)
            """
        guard let raw = try? ClaudeCLI.ask(prompt) else { return nil }
        return Format.parseAsk(raw)
    }
}
