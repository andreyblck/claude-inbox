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
        Notifier.shared.onOpen = { [weak self] id in self?.reveal(id) }
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

    /// Opens the releases page rather than asking GitHub in the background. The
    /// app promises that nothing leaves the machine which Claude Code was not
    /// already sending, and a silent version check would quietly break it.
    @objc private func openReleases() {
        if let url = Bundle.releasesURL { NSWorkspace.shared.open(url) }
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
        menu.addItem(NSMenuItem(title: "Version \(Bundle.version)", action: nil, keyEquivalent: ""))
        let update = NSMenuItem(
            title: "Check for Updates…", action: #selector(openReleases), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
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
        showPanel()
    }

    /// Open the panel, and the row a banner was about. A banner that says a
    /// session needs you and then goes nowhere is worse than no banner.
    private func reveal(_ id: String) {
        showPanel()
        store.open(id: id)
    }

    private func showPanel() {
        guard !popover.isShown else { return }
        guard let button = statusItem.button else { return }
        // The popover is transient: without coming forward first it is dismissed
        // the moment it appears, because the browser the banner was tapped over
        // is still the active app.
        NSApplication.shared.activate()
        store.reload()
        store.panelVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A popover from a status item does not take focus by itself, and a panel
        // you cannot type in or scroll with the keyboard is half a panel.
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        store.panelVisible = false
        store.open(nil)
    }
}

// `--snapshot out.png [--light] [--open N]` draws the panel into a file, on the
// real inbox. A design judged from a description of it is a design nobody has
// looked at; this is how the panel gets looked at without a person holding a
// screenshot key. The backdrop stands in for a blurred wallpaper, because a
// popover's vibrancy has nothing behind it off screen.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
    let out = CommandLine.arguments[flag + 1]
    let light = CommandLine.arguments.contains("--light")
    let openIndex = CommandLine.arguments.firstIndex(of: "--open")
        .flatMap { CommandLine.arguments.count > $0 + 1 ? Int(CommandLine.arguments[$0 + 1]) : nil }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let store = InboxStore()
        store.panelVisible = true
        store.reload()
        let deadline = Date().addingTimeInterval(4)
        while !store.loadedOnce, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let openIndex, store.rows.indices.contains(openIndex) { store.open(store.rows[openIndex]) }

        let host = NSHostingView(rootView: InboxView(store: store))
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 900))
        backdrop.wantsLayer = true
        let wash = CAGradientLayer()
        wash.colors = light
            ? [NSColor(white: 0.93, alpha: 1).cgColor, NSColor(white: 0.86, alpha: 1).cgColor]
            : [NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1).cgColor,
               NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1).cgColor]
        backdrop.layer = wash
        let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = backdrop
        backdrop.addSubview(host)
        for _ in 0..<12 {
            let size = host.fittingSize
            host.frame = NSRect(x: 0, y: 0, width: Theme.panelWidth, height: max(size.height, 1))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        backdrop.frame = host.frame
        window.setContentSize(host.frame.size)
        wash.frame = backdrop.bounds
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { exit(1) }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: out))
        print("\(out)  \(Int(host.frame.width))x\(Int(host.frame.height))")
    }
    exit(0)
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
            ?? Format.phase(fromPrompt: Transcript.command(of: s.transcriptPath))
        s.issue = s.issue ?? Format.issue(fromPrompt: s.lastPrompt)
            ?? Transcript.issue(of: s.transcriptPath)
        if s.state == .idle, let message = s.lastMessage, let reading = Asks.cached(s.sessionId, message: message) {
            s.needsYou = reading.needsYou
            s.line = reading.line
        }
        s.label = s.label ?? Labels.cached(s.sessionId)
        s.state = Format.state(s)
        if let doing = summary.doing { s.activity = [doing] }
        s.asking = summary.asking
        return .session(s)
    }
    rows.sort(by: Inbox.bySeverity)
    // Loud on purpose: the whole point of --dump is to catch what the panel hides.
    if Inbox.unreadable > 0 { print("\n\(Inbox.unreadable) record(s) the decoder refused") }
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
            what = Format.askPhrase(p, max: 60)
        case .session(let s):
            project = Format.label(s)
            what = Format.headline(s, max: 60)
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

if CommandLine.arguments.contains("--accounts") {
    for account in Accounts.all(force: true) {
        print("\(account.loggedIn ? "✓" : "·") \(account.label.padding(toLength: 14, withPad: " ", startingAt: 0))"
            + " \(account.subscription ?? "—")  \(Format.shortPath(account.configDir))")
    }
    exit(0)
}

if CommandLine.arguments.contains("--digest") {
    let rows = Inbox.merge(
        pending: Inbox.readPending(), hooked: Inbox.readSessions(), live: Inbox.readLiveSessions())
    do { print(try Digest.make(for: rows)) } catch { print("failed: \(error)") }
    exit(0)
}

// Capture is safe on its own: it writes only into this app's own store and
// never touches the live credentials. Switching is the one that needs care, so
// it prints what it is about to do.
if CommandLine.arguments.contains("--capture") {
    do {
        let stored = try AccountStore.captureCurrent()
        print("captured \(stored.email) (\(stored.organization ?? "—"))")
    } catch { print("failed: \(error.localizedDescription)") }
    exit(0)
}

if CommandLine.arguments.contains("--stored") {
    let live = AccountStore.liveEmail()
    for account in AccountStore.list() {
        print("\(account.email == live ? "●" : "○") \(account.label.padding(toLength: 16, withPad: " ", startingAt: 0))"
            + " \(account.subscription ?? "—")  captured \(Format.age(account.capturedAt.timeIntervalSince1970))")
    }
    if AccountStore.list().isEmpty { print("(nothing captured yet)") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--switch"), CommandLine.arguments.count > i + 1 {
    let target = CommandLine.arguments[i + 1]
    guard let account = AccountStore.list().first(where: { $0.label == target || $0.email == target })
    else { print("no stored account named \(target)"); exit(1) }
    do {
        print("switching to \(try AccountStore.switchTo(account)) — verified")
    } catch { print("failed: \(error.localizedDescription)") }
    exit(0)
}

// The rollback is the safety net, and an unproven safety net is not one. This
// asks for an account whose email cannot match, so verification must fail and
// the previous credentials must come back untouched.
if CommandLine.arguments.contains("--test-rollback") {
    guard let real = AccountStore.list().first else { print("capture an account first"); exit(1) }
    let before = Accounts.status(of: (NSHomeDirectory() as NSString).appendingPathComponent(".claude"))
    print("before:   \(before.email ?? "nobody")")

    var bogus = real
    bogus.email = "nobody@example.invalid"
    do {
        _ = try AccountStore.switchTo(bogus)
        print("UNEXPECTED: the switch reported success")
    } catch {
        print("rejected: \(error.localizedDescription)")
    }

    Accounts.invalidate()
    let after = Accounts.status(of: (NSHomeDirectory() as NSString).appendingPathComponent(".claude"))
    print("after:    \(after.email ?? "nobody")")
    print(after.loggedIn && after.email == before.email
          ? ">>> ROLLBACK HELD — still signed in as before"
          : ">>> ROLLBACK FAILED")
    exit(0)
}

// Puts a saved token back as Claude Code's live one, with an access list that
// lets Claude Code read it. Needed once because an earlier version wrote the
// item the ordinary way and narrowed it to this app.
if let i = CommandLine.arguments.firstIndex(of: "--repair"), CommandLine.arguments.count > i + 1 {
    let target = CommandLine.arguments[i + 1]
    guard let account = AccountStore.list().first(where: { $0.label == target || $0.email == target }),
          let saved = Keychain.read(service: Keychain.ownService, account: account.id)
    else { print("no saved token for \(target)"); exit(1) }
    let ok = Keychain.writeShared(
        service: Keychain.claudeService, account: account.keychainAccount, data: saved.data)
    print(ok ? "restored \(account.email)" : "could not write the item")
    exit(ok ? 0 : 1)
}

// Puts the item back with an access list that genuinely allows every
// application. `SecAccess` with a NULL application list did not: it left the
// item readable only after a password prompt, so every `claude` on the machine
// started asking for one. `security add-generic-password -A` is the documented
// way to say "anybody", and it is what this uses.
if let i = CommandLine.arguments.firstIndex(of: "--repair-acl"), CommandLine.arguments.count > i + 1 {
    let target = CommandLine.arguments[i + 1]
    guard let account = AccountStore.list().first(where: { $0.label == target || $0.email == target }),
          let saved = Keychain.read(service: Keychain.ownService, account: account.id),
          let secret = String(data: saved.data, encoding: .utf8)
    else { print("no saved token for \(target)"); exit(1) }

    let security = Process()
    security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    security.arguments = [
        "add-generic-password",
        "-a", account.keychainAccount,
        "-s", Keychain.claudeService,
        "-w", secret,
        "-U",  // update the existing item
        "-A",  // any application may read it, without a prompt
    ]
    security.standardOutput = FileHandle.nullDevice
    security.standardError = FileHandle.nullDevice
    try? security.run()
    security.waitUntilExit()
    print(security.terminationStatus == 0
          ? "restored \(account.email) with open access"
          : "security exited \(security.terminationStatus)")
    exit(security.terminationStatus == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no dock icon
app.run()
