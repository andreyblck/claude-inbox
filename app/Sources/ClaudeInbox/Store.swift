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
        watcher = DirectoryWatcher(paths: [Inbox.directory]) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        Task.detached(priority: .userInitiated) {
            Inbox.touchHeartbeat()
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
                if let doing = summary.doing { s.activity = [doing] }
                return .session(s)
            }
            rows.sort(by: Inbox.bySeverity)

            await MainActor.run {
                self.rows = rows
                self.usage = usage
                self.bridgeInstalled = installed
                self.loadedOnce = true
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

    func decide(_ row: Row, allow: Bool) {
        guard case .pending(let item) = row else { return }
        let decision = allow ? "allow" : "deny"
        Inbox.writeVerdict(
            req: item.req,
            decision: decision,
            reason: allow ? "Approved in Claude Inbox" : "Denied in Claude Inbox")
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
