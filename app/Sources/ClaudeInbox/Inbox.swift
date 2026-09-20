import Darwin
import Foundation

/// Reading and writing the bridge's directory. The whole IPC surface lives here:
/// views never touch the filesystem themselves.
///
/// Ported from `spec/lib/inbox.ts`.
enum Inbox {
    static var directory: String {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_INBOX_DIR"], !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude/inbox")
    }

    private static func path(_ parts: String...) -> String {
        parts.reduce(directory) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Every Claude Code config directory the bridge was installed into.
    ///
    /// An account is a config directory, and each keeps its own session registry.
    /// Assuming `~/.claude` is wrong the moment someone runs with CLAUDE_CONFIG_DIR:
    /// their sessions live elsewhere and the inbox reads empty while a dozen are
    /// running. So install.sh records where it went and we read that.
    static func configDirs() -> [String] {
        let listed = (try? String(contentsOfFile: path("config-dirs"), encoding: .utf8)) ?? ""
        let dirs = listed.split(separator: "\n")
            .map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
        return dirs.isEmpty ? [(NSHomeDirectory() as NSString).appendingPathComponent(".claude")] : dirs
    }

    /// Has the bridge ever been installed? An empty inbox and an absent one look
    /// the same to a reader, and "nothing needs you" over a bridge that was never
    /// set up is a screen that lies calmly.
    static var bridgeInstalled: Bool {
        FileManager.default.fileExists(atPath: path("config-dirs"))
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static func readJSONDir<T: Decodable>(_ dir: String, as type: T.Type) -> [T] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let file = (dir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: file) else { return nil }
            // A half-written or hand-edited file is skipped, never fatal.
            return try? decoder.decode(T.self, from: data)
        }
    }

    static func readPending() -> [PendingItem] { readJSONDir(path("pending"), as: PendingItem.self) }
    static func readSessions() -> [SessionRecord] { readJSONDir(path("sessions"), as: SessionRecord.self) }

    static func readUsage() -> [UsageRecord] {
        // One row per account. Several sessions on one account write the same
        // numbers; the freshest reading is the true one.
        var byAccount: [String: UsageRecord] = [:]
        for record in readJSONDir(path("usage"), as: UsageRecord.self) {
            if let seen = byAccount[record.configDir], seen.ts >= record.ts { continue }
            byAccount[record.configDir] = record
        }
        return Array(byAccount.values)
    }

    // MARK: - Liveness

    /// When a process actually started, straight from the kernel.
    ///
    /// The registry's `procStart` string is UTC with no zone marker while `ps`
    /// prints local time, so comparing them can only ever fail — which is how a
    /// liveness check once reported every session dead and emptied the whole view.
    /// `sysctl` gives an instant, which has no zone to disagree about, and costs
    /// no subprocess.
    private static func processStart(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// A session is registered a moment after its process starts, never before.
    private static let startTolerance: TimeInterval = 120

    /// Is this pid still the process the registry recorded?
    ///
    /// Every uncertainty resolves to alive. Holding a finished row a little too
    /// long costs a line of stale text; being wrong the other way hides the whole
    /// product.
    static func isAlive(pid: Int?, startedAt: Double?) -> Bool {
        guard let pid, pid > 0 else { return false }
        guard let started = processStart(Int32(pid)) else { return false }
        guard let startedAt, startedAt > 0 else { return true }
        return abs(started.timeIntervalSince1970 - startedAt / 1000) < startTolerance
    }

    /// Claude Code's own status vocabulary, from the 2.1.278 validator:
    /// `busy | shell | idle | waiting`.
    private static func liveState(_ status: String?) -> InboxState {
        switch status {
        // Something wants the human but the bridge has no request for it, so it
        // is a dialog only the terminal can answer.
        case "waiting": .blockedDialog
        // "shell" is idle with the user at a ! prompt. Blue here would leave a
        // Working row standing for as long as someone sits in their shell.
        case "shell", "idle": .idle
        default: .working
        }
    }

    /// The two kinds a person is having a session with. The rest is machinery.
    private static let humanKinds: Set<String> = ["interactive", "bg"]

    /// Claude Code keeps the transcript beside the project, keyed by the cwd with
    /// every non-alphanumeric character replaced by a dash.
    static func transcriptPath(configDir: String, cwd: String?, sessionId: String?) -> String? {
        guard let cwd, let sessionId else { return nil }
        let slug = cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }.map(String.init).joined()
        return (configDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(slug)/\(sessionId).jsonl")
    }

    struct LiveRegistry: Sendable {
        var sessions: [SessionRecord]
        /// False when no registry could be read at all. Liveness is then unknown,
        /// and treating "absent" as "gone" would mark every session finished.
        var observed: Bool
    }

    static func readLiveSessions() -> LiveRegistry {
        var out: [SessionRecord] = []
        var observed = false
        let liveDecoder = JSONDecoder()

        for configDir in configDirs() {
            let dir = (configDir as NSString).appendingPathComponent("sessions")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            observed = true
            for name in names where name.hasSuffix(".json") {
                let file = (dir as NSString).appendingPathComponent(name)
                guard let data = FileManager.default.contents(atPath: file),
                      let row = try? liveDecoder.decode(LiveSession.self, from: data),
                      let sessionId = row.sessionId
                else { continue }
                // Daemons and workers share this directory and are not sessions.
                if let kind = row.kind, !humanKinds.contains(kind) { continue }
                guard isAlive(pid: row.pid, startedAt: row.startedAt) else { continue }

                var record = SessionRecord(
                    sessionId: sessionId,
                    state: liveState(row.status),
                    ts: (row.statusUpdatedAt ?? row.startedAt ?? Date().timeIntervalSince1970 * 1000) / 1000
                )
                record.cwd = row.cwd
                record.name = row.name
                record.pid = row.pid
                record.waitingFor = row.waitingFor
                record.configDir = configDir
                record.transcriptPath = transcriptPath(configDir: configDir, cwd: row.cwd, sessionId: sessionId)
                out.append(record)
            }
        }
        return LiveRegistry(sessions: out, observed: observed)
    }

    // MARK: - Merge

    private static let finishedTTL: TimeInterval = 60 * 60

    /// One row per session, from three sources that each know something the others
    /// don't. The rule is **the freshest observation wins**, not a fixed pecking
    /// order: the registry does not know a session ended cleanly, and the hooks do
    /// not know a new turn started until the next event fires.
    static func merge(pending: [PendingItem], hooked: [SessionRecord], live: LiveRegistry) -> [Row] {
        var merged: [String: SessionRecord] = [:]
        for session in live.sessions { merged[session.sessionId] = session }

        let now = Date().timeIntervalSince1970
        for record in hooked {
            if var alive = merged[record.sessionId] {
                // SessionEnd is a fact the registry cannot contradict: the session
                // is over even if the process lingers.
                let terminal = record.state == .done || record.state == .failed
                let useHooked = terminal || record.ts >= alive.ts
                alive.phase = record.phase ?? alive.phase
                alive.lastMessage = record.lastMessage ?? alive.lastMessage
                alive.lastPrompt = record.lastPrompt ?? alive.lastPrompt
                alive.transcriptPath = record.transcriptPath ?? alive.transcriptPath
                alive.permissionMode = record.permissionMode ?? alive.permissionMode
                if useHooked {
                    alive.state = record.state
                    alive.ts = record.ts
                }
                merged[record.sessionId] = alive
                continue
            }

            // Not in the live registry. If we could read the registry at all, the
            // process is gone and the session is over — including the common case
            // of a killed window, which fires no SessionEnd and leaves the record
            // on whatever Stop last wrote. If we could NOT read it, liveness is
            // unknown and the last thing we heard stands.
            if !live.observed || record.demo == true {
                merged[record.sessionId] = record
                continue
            }
            guard now - record.ts < finishedTTL else { continue }
            var ended = record
            if ended.state != .done && ended.state != .failed { ended.state = .done }
            merged[ended.sessionId] = ended
        }

        let blocked = Set(pending.map(\.sessionId))
        // A pending request outranks the session it belongs to: it is the same
        // session, and the decision is the more urgent truth about it.
        return pending.map(Row.pending)
            + merged.values.filter { !blocked.contains($0.sessionId) }.map(Row.session)
    }

    /// Within a group: by rank, then by age — oldest first where the row has been
    /// kept waiting, newest first where it is a result to read.
    static func bySeverity(_ a: Row, _ b: Row) -> Bool {
        let ga = a.state.group, gb = b.state.group
        if ga != gb { return ga < gb }
        if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
        return ga == .finished || ga == .answered ? a.ts > b.ts : a.ts < b.ts
    }

    // MARK: - Writing

    /// Atomic, because a hook is polling for this exact file in a tight loop.
    static func writeVerdict(req: String, decision: String, reason: String) {
        let dir = path("verdicts")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = (dir as NSString).appendingPathComponent("\(req).json")
        let tmp = dest + ".\(ProcessInfo.processInfo.processIdentifier).tmp"
        let payload = ["decision": decision, "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
        try? FileManager.default.moveItem(atPath: tmp, toPath: dest)
    }

    /// Tell the waiting hooks that somebody is on this end.
    ///
    /// A permission hook blocks for its whole timeout waiting for a verdict. With
    /// nothing listening that is a dead freeze before every prompt, for an answer
    /// that was never coming.
    static func touchHeartbeat() {
        let now = String(Int(Date().timeIntervalSince1970))
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? now.write(toFile: path("heartbeat"), atomically: true, encoding: .utf8)
    }
}
