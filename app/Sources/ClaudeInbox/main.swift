import AppKit
import SwiftUI

/// The bar answers one question in under 200 ms: **am I needed right now?**
///
/// The count is blocked-only. Every session goes idle after every turn, so
/// counting answers would make the badge a number that is always large and never
/// urgent — the glyph carries that instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = InboxStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var observation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.target = self

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: InboxView(store: store))
        // Let the panel's own material show. A hosting view paints an opaque
        // backing by default, which sits on top of the popover's vibrancy and
        // turns a native panel into a rectangle glued over the desktop.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        popover.contentViewController = host

        store.start()
        render()
        // The bar redraws when the inbox changes, which is what the watcher is
        // for; this keeps the glyph in step with it.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let waiting = store.waiting.count
        let answered = store.answered.count
        let running = store.running.count

        let symbol: String
        if waiting > 0 { symbol = "bell.fill" }
        else if answered > 0 { symbol = "bubble.left.fill" }
        else if running > 0 { symbol = "circle.fill" }
        else { symbol = "circle" }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude sessions")?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.imagePosition = waiting > 0 ? .imageLeading : .imageOnly
        button.imageHugsTitle = true
        // The count is the whole message when there is one, so it is set in the
        // bar's own weight rather than left to the default label font.
        button.attributedTitle = NSAttributedString(
            string: waiting > 0 ? " \(waiting)" : "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .baselineOffset: 0.5,
            ])
        button.toolTip =
            waiting > 0 ? "\(waiting) waiting for you"
            : answered > 0 ? "\(answered) answered"
            : "Claude sessions"
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        store.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A popover from a status item does not take focus by itself, and a panel
        // you cannot type in or scroll with the keyboard is half a panel.
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        store.open(nil)
    }
}

// `--dump` prints what the panel would show, so the port can be diffed against
// spec/ on the same data instead of being taken on trust.
if CommandLine.arguments.contains("--dump") {
    Inbox.touchHeartbeat()
    var rows = Inbox.merge(
        pending: Inbox.readPending(),
        hooked: Inbox.readSessions(),
        live: Inbox.readLiveSessions())
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
    var group: StateGroup?
    for row in rows {
        if row.state.group != group {
            group = row.state.group
            print("\n" + group!.title)
        }
        let project: String
        let what: String
        switch row {
        case .pending(let p):
            project = Format.projectName(cwd: p.cwd, fallback: p.sessionId, name: nil)
            what = Format.askPhrase(p)
        case .session(let s):
            project = Format.projectName(cwd: s.cwd, fallback: s.sessionId, name: s.name)
            what = s.waitingFor ?? Format.subject(s, max: 60)
        }
        var phase: String?
        if case .session(let s) = row { phase = s.phase }
        let tail = phase.map { $0 != what ? "\($0) · \(Format.age(row.ts))" : Format.age(row.ts) }
            ?? Format.age(row.ts)
        print("  " + project.padding(toLength: max(16, project.count), withPad: " ", startingAt: 0)
            + "  " + what + "  ·  " + tail)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no dock icon
app.run()
