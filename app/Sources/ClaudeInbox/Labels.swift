import Foundation

/// A name for a session that named no issue: "GSC" where the row said
/// `skyaccess-d5`.
///
/// Generated once per session by the `claude` on the machine, off to the side,
/// and kept on disk — a name that changed between launches would be a second
/// thing to learn. Ten seconds a call is fine for something nobody waits on and
/// wrong for anything on the way to a redraw, so nothing here is ever awaited by
/// a view: a row shows the session name until the label lands.
enum Labels {
    private struct Entry: Codable { var label: String; var at: Double }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    nonisolated(unsafe) private static var inFlight: Set<String> = []
    /// A model that would not name it once is asked again later, not every ten
    /// seconds for the rest of the session.
    nonisolated(unsafe) private static var refusedAt: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 15 * 60
    private static let keepFor: TimeInterval = 14 * 24 * 3600

    /// One at a time: a dozen sessions are a dozen ten-second subprocesses, and
    /// nobody is waiting on any of them.
    private static let queue = DispatchQueue(label: "claude-inbox.labels", qos: .utility)

    private static var file: String {
        (Inbox.directory as NSString).appendingPathComponent("labels.json")
    }

    private static func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = saved
    }

    static func cached(_ sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return entries[sessionId]?.label
    }

    /// A name the person typed. It wins for good: generation only ever fills a gap.
    static func set(_ sessionId: String, label: String) {
        let clean = Format.truncate(Format.oneLine(label), Limits.project)
        lock.lock()
        loadLocked()
        if clean.isEmpty { entries[sessionId] = nil } else {
            entries[sessionId] = Entry(label: clean, at: Date().timeIntervalSince1970)
        }
        saveLocked()
        lock.unlock()
    }

    /// Ask for a name if this session has none and nobody is already asking.
    static func want(_ s: SessionRecord, then done: @escaping @Sendable () -> Void) {
        let id = s.sessionId
        lock.lock()
        loadLocked()
        let refused = refusedAt[id].map { Date().timeIntervalSince($0) < retryAfter } ?? false
        guard entries[id] == nil, !inFlight.contains(id), !refused else {
            lock.unlock()
            return
        }
        inFlight.insert(id)
        lock.unlock()

        let path = s.transcriptPath
        let lastPrompt = s.lastPrompt
        let project = Format.projectName(cwd: s.cwd, fallback: nil, name: nil)
        queue.async {
            let label = generate(transcriptPath: path, lastPrompt: lastPrompt, project: project)
            lock.lock()
            inFlight.remove(id)
            if let label {
                entries[id] = Entry(label: label, at: Date().timeIntervalSince1970)
                saveLocked()
            } else {
                refusedAt[id] = Date()
            }
            lock.unlock()
            if label != nil { done() }
        }
    }

    private static func saveLocked() {
        let cutoff = Date().timeIntervalSince1970 - keepFor
        entries = entries.filter { $0.value.at > cutoff }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    private static func generate(transcriptPath: String?, lastPrompt: String?, project: String) -> String? {
        var asked = Transcript.prompts(of: transcriptPath)
        if asked.isEmpty, let only = Format.userPrompt(lastPrompt) { asked = [only] }
        guard !asked.isEmpty else { return nil }
        let did = Transcript.activity(of: transcriptPath, max: 4)

        let prompt = """
            You name parallel working sessions so a person can tell them apart at a \
            glance. Below is what the person asked for in one session, and what the \
            session has been doing.

            Reply with ONE name: 1–3 words, at most 20 characters, no quotes, no full \
            stop — what the person would call this piece of work out loud. Examples: \
            GSC, Pricing email, Menu icon, Verify mine. Write it in the language the \
            person wrote in. Do not answer the request and do not explain.

            The name is about WHY the session was opened, not what it happens to be \
            doing this minute. If the request names a topic, product or system, that \
            is the name. If the request is only a slash command, take the name from \
            it: /sky-verify-mine -> Verify mine. The list of actions is only a hint, \
            for when the request names nothing.

            The name must tell this session apart from its neighbours. The project is \
            called "\(project)" — neither that word nor the prefix of its issue keys \
            can be the name: every session there is called that.

            What the person asked for:
            \(asked.map { "- " + Format.truncate(Format.oneLine($0), 300) }.joined(separator: "\n"))

            What the session did:
            \(did.isEmpty ? "- (nothing yet)" : did.map { "- " + $0 }.joined(separator: "\n"))
            """
        guard let raw = try? ClaudeCLI.ask(prompt) else { return nil }
        return Format.cleanLabel(raw)
    }
}
