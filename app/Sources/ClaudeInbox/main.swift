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
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.target = self
        // Left click opens the panel; right click is for the things you set once
        // and forget, which do not belong inside the panel itself.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: InboxView(store: store))
        // Without this the popover does not ask SwiftUI how big the panel is: it
        // picks a size, the content is laid out against a different one, and the
        // result is a panel whose left edge is off the side of its own window.
        host.sizingOptions = [.preferredContentSize]
        // Let the panel's own material show. A hosting view paints an opaque
        // backing by default, which sits on top of the popover's vibrancy and
        // turns a native panel into a rectangle glued over the desktop.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        popover.contentSize = NSSize(width: Theme.panelWidth, height: 320)
        popover.contentViewController = host

        Notifier.shared.start()
        Notifier.shared.onDecision = { [weak self] req, allow in
            self?.store.decide(req: req, allow: allow)
        }
        store.start()
        render()

        Hotkey.shared.register { [weak self] in self?.toggle() }
        // A menu bar app that is not running when a session blocks never tells
        // anyone anything, so this is offered on first launch rather than hidden
        // in a menu nobody opens.
        if !LoginItem.enabled, !UserDefaults.standard.bool(forKey: "askedAboutLogin") {
            UserDefaults.standard.set(true, forKey: "askedAboutLogin")
            LoginItem.set(true)
        }
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

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let login = NSMenuItem(
            title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.enabled ? .on : .off
        menu.addItem(login)

        let inbound = Settings.inbound()
        let deliver = NSMenuItem(
            title: "Deliver notes to bypassing sessions", action: #selector(toggleInbound),
            keyEquivalent: "")
        deliver.target = self
        deliver.state = inbound == .accept ? .on : .off
        // The trade, where the switch is, rather than in a document nobody reads.
        deliver.toolTip = """
            Sets crossSessionInbound. While this is off, Claude Code parks notes             sent from here to a session that bypasses prompts, and you release             them in the terminal. While it is on, anything running as you on this             machine can steer such a session.
            """
        menu.addItem(deliver)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Panel: ⌥Space", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Claude Inbox", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // put the click back to opening the panel
    }

    @objc private func toggleLoginItem() {
        LoginItem.set(!LoginItem.enabled)
    }

    @objc private func toggleInbound() {
        Settings.setInbound(Settings.inbound() == .accept ? .hold : .accept)
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

// `--send <pid> <text>` exercises the peer channel without the panel, so the
// transport can be tested apart from the UI that drives it.
if let i = CommandLine.arguments.firstIndex(of: "--send"),
   CommandLine.arguments.count > i + 2,
   let pid = Int(CommandLine.arguments[i + 1])
{
    do {
        try Peer.send(CommandLine.arguments[i + 2], toPID: pid)
        print("delivered to pid \(pid)")
        exit(0)
    } catch {
        print("failed: \(error.localizedDescription)")
        exit(1)
    }
}

// `--md` shows what the parser found in a real answer, so the block shapes can
// be checked without opening a panel.
if let i = CommandLine.arguments.firstIndex(of: "--md"), CommandLine.arguments.count > i + 1 {
    let text = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)) ?? ""
    for block in Markdown.parse(text) {
        switch block {
        case .heading(let level, let text): print("heading \(level)  \(text.prefix(60))")
        case .paragraph(let text): print("paragraph    \(text.prefix(60))…")
        case .code(let lang, let text):
            print("code \(lang ?? "—")     \(text.split(separator: "\n").count) lines")
        case .list(let items, let ordered): print("list \(ordered ? "1." : "• ")     \(items.count) items")
        case .quote(let text): print("quote        \(text.prefix(50))")
        case .table(let header, let rows):
            print("TABLE        \(header.count) cols × \(rows.count) rows — \(header.joined(separator: " | "))")
        case .rule: print("rule")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--login-status") {
    print("bundle:  \(Bundle.main.bundlePath)")
    print("enabled: \(LoginItem.enabled)")
    print("register: \(LoginItem.set(true) ? "ok" : "failed")")
    print("enabled after: \(LoginItem.enabled)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no dock icon
app.run()
