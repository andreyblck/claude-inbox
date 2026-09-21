import Foundation
import Observation

/// What the views read. Everything above this line is pure; everything below it
/// is a picture of the inbox at one moment.
@MainActor
@Observable
final class InboxStore {
    private(set) var rows: [Row] = []
    private(set) var usage: [UsageRecord] = []
    private(set) var bridgeInstalled = true
    private(set) var loadedOnce = false
    /// Whether the panel is on screen. Anything that moves only moves then.
    var panelVisible = false

    /// The expensive reads, for the one row being looked at.
    private(set) var openRowID: String?
    private(set) var narration: String?
    private(set) var activity: [String] = []

    private var timer: Timer?
    private var watcher: DirectoryWatcher?

    var waiting: [Row] { rows.filter { $0.state.group == .waiting } }
    var answered: [Row] { rows.filter { $0.state.group == .answered } }
    var running: [Row] { rows.filter { $0.state.group == .running } }
    var finished: [Row] { rows.filter { $0.state.group == .finished } }

    func start() {
        reload()
        // The directory is the protocol, so watching it is the notification: no
        // deeplink to fire, nothing to wake, no error toast when the other end is
        // not there. The timer is only for the clocks — "2m" has to become "3m".
        // Only what the bridge writes. Watching the whole directory meant
        // watching our own heartbeat, which every read rewrote: a read caused a
        // write caused a read, four times a second, at a quarter to a half of a
        // core — and each pass redrew the list under whoever was typing in it.
        let watched = ["sessions", "pending", "usage"].map {
            (Inbox.directory as NSString).appendingPathComponent($0)
        }
        watcher = DirectoryWatcher(paths: watched) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        Task.detached(priority: .userInitiated) {
            Inbox.touchHeartbeat()
            Inbox.resetUnreadable()
            let pending = Inbox.readPending()
            let hooked = Inbox.readSessions()
            let live = Inbox.readLiveSessions()
            let usage = Inbox.readUsage()
            let installed = Inbox.bridgeInstalled

            var rows = Inbox.merge(pending: pending, hooked: hooked, live: live)
            // Fill in what makes a row readable. Both the title and the current
            // move come from one cached read of the transcript tail.
            rows = rows.map { row in
                guard case .session(var s) = row else { return row }
                let summary = Transcript.summary(of: s.transcriptPath)
                s.title = s.title ?? summary.title
                s.saying = summary.saying
                s.lastPrompt = s.lastPrompt ?? summary.prompt
                s.phase = s.phase ?? Format.phase(fromPrompt: s.lastPrompt)
                    ?? Format.phase(fromPrompt: Transcript.command(of: s.transcriptPath))
                s.issue = s.issue ?? Format.issue(fromPrompt: s.lastPrompt)
                    ?? Transcript.issue(of: s.transcriptPath)
                // A turn that ended is read once: is it done, or is it standing
                // there needing a decision? Only a live session is worth asking
                // about, and only `Stop` leaves one in this state.
                if s.state == .idle, s.pid != nil, s.demo != true, let message = s.lastMessage, !message.isEmpty {
                    if let reading = Asks.cached(s.sessionId, message: message) {
                        s.needsYou = reading.needsYou
                        s.line = reading.line
                        s.replies = reading.replies ?? []
                    } else {
                        Asks.want(s.sessionId, message: message) { Task { @MainActor [weak self] in self?.reload() } }
                    }
                }
                s.label = s.label ?? Labels.cached(s.sessionId)
                s.state = Format.state(s)
                Linear.remember(from: s.lastPrompt)
                if s.issue != nil, Linear.url(for: s.issue) == nil {
                    Linear.remember(from: Transcript.prompts(of: s.transcriptPath).joined(separator: "\n"))
                }
                s.search = [Format.label(s), Format.projectName(cwd: s.cwd, fallback: s.sessionId, name: s.name),
                            Format.headline(s, max: 300), Format.subject(s, max: 300), s.phase ?? "", s.issue ?? ""]
                    .joined(separator: " ").lowercased()
                s.unread = s.state.group == .answered && !Reads.isRead(s.sessionId, ts: s.ts)
                // Only for a session still running: a name for one that is over
                // is ten seconds of quota spent on something nobody will read.
                if s.issue == nil, s.label == nil, s.pid != nil, s.demo != true {
                    Labels.want(s) { Task { @MainActor [weak self] in self?.reload() } }
                }
                if let doing = summary.doing { s.activity = [doing] }
                s.asking = summary.asking
                return .session(s)
            }
            rows.sort(by: Inbox.bySeverity)

            await MainActor.run {
                self.rows = rows
                self.usage = usage
                self.bridgeInstalled = installed
                self.loadedOnce = true
                if let wanted = self.wanted, let row = rows.first(where: { $0.answers(to: wanted) }) {
                    self.wanted = nil
                    self.open(row)
                }
                // Announcing is a side effect of knowing, so it belongs with the
                // read rather than on a schedule of its own.
                Notifier.shared.sync(
                    pending: pending,
                    waiting: rows.compactMap {
                        if case .session(let s) = $0, s.state == .blockedDialog { return s } else { return nil }
                    })
            }
        }
    }

    /// Opening a row is what pays for the expensive read — the full answer and the
    /// trail of what it touched.
    func open(_ row: Row?) {
        guard let row else {
            openRowID = nil
            narration = nil
            activity = []
            return
        }
        openRowID = row.id
        if case .session(let s) = row, s.unread {
            Reads.mark(s.sessionId, ts: s.ts)
            rows = rows.map { other in
                guard case .session(var o) = other, o.sessionId == s.sessionId else { return other }
                o.unread = false
                return .session(o)
            }
        }
        let path = row.transcriptPath
        Task.detached(priority: .userInitiated) {
            let narration = Transcript.narration(of: path)
            let activity = Transcript.activity(of: path)
            await MainActor.run {
                guard self.openRowID == row.id else { return }  // moved on already
                self.narration = narration
                self.activity = activity
            }
        }
    }

    /// A row the panel has been asked to open but has not read yet.
    private var wanted: String?

    /// Open by id — what a tapped banner has to work with. The row may not be in
    /// hand yet, so the wish is remembered and granted by the next read.
    func open(id: String) {
        if let row = rows.first(where: { $0.answers(to: id) }) {
            wanted = nil
            open(row)
        } else {
            wanted = id
            reload()
        }
    }

    /// Answer by request id — what a notification action has to work with.
    func decide(req: String, allow: Bool) {
        guard let row = rows.first(where: { if case .pending(let p) = $0 { return p.req == req } else { return false } })
        else {
            // The panel may not have loaded this row yet; the verdict still goes.
            Inbox.writeVerdict(
                req: req, decision: allow ? "allow" : "deny",
                reason: allow ? "Approved in Claude Inbox" : "Denied in Claude Inbox")
            Notifier.shared.withdraw(req)
            reload()
            return
        }
        decide(row, allow: allow)
    }

    // MARK: - Starting and summarising

    private(set) var digest: String?
    private(set) var working = false
    private(set) var problem: String?

    /// One paragraph for a dozen sessions — the question a person comes back to
    /// the machine with, which no single row answers.
    func summarise() {
        guard !working else { return }
        working = true
        problem = nil
        let rows = self.rows
        Task.detached(priority: .userInitiated) {
            do {
                let text = try Digest.make(for: rows)
                await MainActor.run { self.digest = text; self.working = false }
            } catch {
                await MainActor.run { self.problem = error.localizedDescription; self.working = false }
            }
        }
    }

    /// Put the hooks in, from the copy inside the app. Nothing reports in until
    /// this has run once, and the panel says so rather than looking quiet.
    func installBridge(uninstall: Bool = false) {
        guard !working else { return }
        working = true
        problem = nil
        Task.detached(priority: .userInitiated) {
            do {
                _ = try Bridge.run(uninstall: uninstall)
                await MainActor.run {
                    self.working = false
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.problem = error.localizedDescription
                    self.working = false
                }
            }
        }
    }

    func clearDigest() {
        digest = nil
        problem = nil
    }

    /// A session started here runs on the account chosen here and can be picked
    /// up in a terminal later — nothing is lost by starting it from a panel.
    func launch(prompt: String, directory: String, configDir: String?) {
        guard !working else { return }
        working = true
        problem = nil
        Task.detached(priority: .userInitiated) {
            do {
                _ = try Launcher.start(prompt: prompt, in: directory, configDir: configDir)
                await MainActor.run {
                    self.working = false
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.problem = error.localizedDescription
                    self.working = false
                }
            }
        }
    }

    func rename(_ sessionId: String, to label: String) {
        Labels.set(sessionId, label: label)
        reload()
    }

    /// Answer a question from the panel. The answer is the decision: it rides in
    /// `updatedInput`, and if we cannot build one Claude Code accepts we do not
    /// send anything — a refused input is dropped in silence.
    func answer(_ row: Row, answers: [String: [String]]) {
        guard case .pending(let item) = row,
              let input = Format.answerInput(item, answers: answers)
        else {
            problem = "That answer is not one Claude Code would accept — answer it in the terminal."
            return
        }
        Inbox.writeVerdict(req: item.req, decision: "allow", reason: "Answered in Claude Inbox", input: input)
        Notifier.shared.withdraw(item.req)
        rows.removeAll { $0.id == row.id }
        reload()
    }

    /// Approve a plan. Same rule: the allow has to carry the input back.
    func approvePlan(_ row: Row) {
        guard case .pending(let item) = row else { return }
        Inbox.writeVerdict(req: item.req, decision: "allow", reason: "Approved in Claude Inbox",
                           input: item.toolInput)
        Notifier.shared.withdraw(item.req)
        rows.removeAll { $0.id == row.id }
        reload()
    }

    func decide(_ row: Row, allow: Bool, grant: Format.Grant? = nil) {
        guard case .pending(let item) = row else { return }
        let decision = allow ? "allow" : "deny"
        Inbox.writeVerdict(
            req: item.req,
            decision: decision,
            reason: allow ? "Approved in Claude Inbox" : "Denied in Claude Inbox",
            grants: grant.map { [$0.suggestion] } ?? [])
        // A request answered here should not leave a banner behind offering to
        // answer it again.
        Notifier.shared.withdraw(item.req)
        // Optimistic: the verdict is a local file write, and a spinner on one is
        // a lie about how long it takes.
        rows.removeAll { $0.id == row.id }
        reload()
    }
}

/// Watches directories for any change, coalescing bursts.
///
/// A dozen sessions ending a turn at once is a dozen writes; one redraw covers
/// all of them.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable () -> Void

    init(paths: [String], handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // coalesce
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
