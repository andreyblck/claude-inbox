import SwiftUI

/// The panel. This is what a menu row could not be and why the app exists: a
/// card you open and read the whole answer in, with the decision on that card.
struct InboxView: View {
    @Bindable var store: InboxStore
    @State private var contentHeight: CGFloat = 0
    @State private var composing = false
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var searching: Bool

    /// Everything the keyboard can land on, in the order it is drawn.
    private var visible: [Row] {
        guard !query.isEmpty else { return store.rows }
        let needle = query.lowercased()
        return store.rows.filter { row in
            if case .session(let s) = row, !s.search.isEmpty { return s.search.contains(needle) }
            return Self.haystack(row).lowercased().contains(needle)
        }
    }

    private static func haystack(_ row: Row) -> String {
        switch row {
        case .pending(let p):
            Format.projectName(cwd: p.cwd, fallback: p.sessionId, name: nil) + " " + Format.askPhrase(p, max: 200)
        case .session(let s):
            // Both names: the issue is what the row shows, the session name is
            // what the terminal tab shows, and either is a fair thing to type.
            Format.label(s) + " " + Format.projectName(cwd: s.cwd, fallback: s.sessionId, name: s.name)
                + " " + Format.subject(s, max: 300) + " " + (s.phase ?? "")
        }
    }

    /// Said when there is nothing to say. One per day, so it is a small surprise
    /// and never a slot machine.
    private static var quiet: String {
        let lines = [
            "Sessions appear the moment one blocks on a decision.",
            "Every session is minding its own business.",
            "No one is waiting. Go make coffee.",
            "All quiet. The machines have it covered.",
            "Inbox zero, and nobody had to archive anything.",
        ]
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return lines[day % lines.count]
    }

    private func rows(in group: StateGroup) -> [Row] {
        visible.filter { $0.state.group == group }
    }

    private var focusedID: String? {
        visible.indices.contains(cursor) ? visible[cursor].id : nil
    }

    private var focusedRow: Row? {
        visible.indices.contains(cursor) ? visible[cursor] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(store: store, composing: $composing)
            search
            Divider()

            if composing {
                NewTask(store: store, composing: $composing)
                Divider()
            }
            // Silence that looks like nothing happening, but is a permission
            // nobody was told about, is the worst failure this app can have.
            if Notifier.shared.settled == true, !Notifier.shared.authorized {
                HStack(spacing: Theme.Space.step) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(.secondary)
                    Text("Notifications are off, so nothing will interrupt you.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Space.step)
                    Button("Open Settings") { Notifier.shared.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, Theme.Space.wide)
                .padding(.vertical, Theme.Space.step)
                Divider()
            }
            if store.digest != nil || store.problem != nil {
                DigestBanner(store: store)
                Divider()
            }

            Group {
                if !store.bridgeInstalled {
                    // A quiet machine and a disconnected one look identical to a
                    // reader. Say which one this is — and, from a downloaded
                    // copy, fix it with one button rather than one script.
                    Placeholder(
                        symbol: "powerplug",
                        title: "Connect to Claude Code",
                        detail: Bridge.bundledInstaller == nil
                            ? "Run bridge/install.sh from the clone once. Until then nothing reports in."
                            : "Claude Inbox adds a few hooks to Claude Code so every session on this Mac reports in. Your settings.json is backed up first.",
                        action: Bridge.bundledInstaller == nil ? nil
                            : (store.working ? "Installing…" : "Install Bridge", { store.installBridge() }))
                } else if !store.loadedOnce {
                    // For the instant before the first read lands, "nothing
                    // needs you" is a claim nobody has checked.
                    Placeholder(
                        symbol: "ellipsis",
                        title: "Reading the Inbox",
                        detail: "")
                } else if store.rows.isEmpty {
                    Placeholder(
                        symbol: "checkmark.circle",
                        title: "Nothing Needs You",
                        detail: Self.quiet)
                } else {
                    list
                }
            }

            if let account = store.usage.first {
                Divider()
                Footer(usage: account)
            }
        }
        .frame(width: Theme.panelWidth)
        .background(VisualEffect())
        .onAppear {
            searching = true
            cursor = 0
        }
    }

    /// Always focused, the way the tools this sits beside behave. Typing filters,
    /// the arrows move, Return acts — a panel that opens on a keystroke and then
    /// needs a mouse for everything has moved the work rather than removed it.
    private var search: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($searching)
                .onKeyPress { press in
                    switch press.key {
                    case .downArrow: move(1); return .handled
                    case .upArrow: move(-1); return .handled
                    case .return:
                        if press.modifiers.contains(.command) { decideFocused(true) } else { openFocused() }
                        return .handled
                    case .delete where press.modifiers.contains(.command):
                        decideFocused(false)
                        return .handled
                    case .init("l") where press.modifiers.contains(.command):
                        if case .session(let s)? = focusedRow { Linear.open(s.issue) }
                        return .handled
                    case .init("t") where press.modifiers.contains(.command):
                        if case .session(let s)? = focusedRow { Terminal.reveal(pid: s.pid) }
                        return .handled
                    case .init("1"), .init("2"), .init("3"), .init("4"), .init("5"),
                         .init("6"), .init("7"), .init("8"), .init("9"):
                        // ⌘1…9 belong to the waiting rows only. Opening is the
                        // safe landing: a tool call must never run because a
                        // finger was one key off.
                        guard press.modifiers.contains(.command),
                              let index = Int(press.characters), index >= 1
                        else { return .ignored }
                        let waiting = rows(in: .waiting)
                        guard waiting.indices.contains(index - 1),
                              let at = visible.firstIndex(where: { $0.id == waiting[index - 1].id })
                        else { return .handled }
                        cursor = at
                        openFocused()
                        return .handled
                    case .escape:
                        // First press clears a filter, second closes: leaving the
                        // panel open with a filter nobody can see is a trap.
                        if query.isEmpty { closePanel() } else { query = ""; cursor = 0 }
                        return .handled
                    default: return .ignored
                    }
                }
            if !query.isEmpty {
                Button { query = ""; cursor = 0 } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(shortcutHint)
                .font(Theme.Font.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.step)
        .frame(height: 28)
        // The search field every Mac app has: a quiet fill, no border, the
        // magnifier inside it.
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .fill(.primary.opacity(0.06)))
        .padding(.horizontal, Theme.Space.gap)
        .padding(.bottom, Theme.Space.gap)
    }

    /// Only ever names what the focused row can actually do.
    private var shortcutHint: String {
        guard let id = focusedID, let row = visible.first(where: { $0.id == id }) else { return "" }
        if case .pending(let p) = row {
            if p.kind == "question" { return "answer below · ⌘⌫ dismiss" }
            if p.kind == "plan" { return "⌘↵ approve plan · ⌘⌫ reject" }
            return "⌘↵ approve · ⌘⌫ deny"
        }
        if case .session(let s) = row, Linear.url(for: s.issue) != nil { return "↵ open · ⌘L Linear · ⌘T terminal" }
        return "↵ open · ⌘T terminal"
    }

    private var list: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.wide) {
                section(.waiting, rows(in: .waiting))
                section(.answered, rows(in: .answered))
                section(.running, rows(in: .running))
                // Finished rows are history the moment they are read. Five is
                // what "what just landed" needs; the rest is a log.
                section(.finished, Array(rows(in: .finished).prefix(5)))
                if visible.isEmpty, !query.isEmpty {
                    Text("No Results for “\(query)”")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.room)
                }
            }
            .padding(.horizontal, Theme.Space.gap)
            .padding(.top, Theme.Space.tight)
            .padding(.bottom, Theme.Space.gap)
            // Fill the panel, do not restate its width: this stack carries the
            // horizontal padding, so naming the same number here makes it wider
            // than its own parent.
            .frame(maxWidth: .infinity, alignment: .leading)
            // A session that gets an answer moves from Running to Answered; it
            // should be seen to move, or the list just reshuffles under the eye.
            // Not while filtering: there the list has to keep up with the keys, and
            // an animation per keystroke is a list that is always catching up.
            .animation(query.isEmpty ? Theme.shuffle : nil, value: visible.map { $0.id + $0.state.rawValue })
            .measureHeight(into: $contentHeight)
        }
        .scrollIndicators(.never)
        // As short as one row, never taller than the panel is allowed to be.
        .frame(height: min(max(contentHeight, 1), Theme.panelMaxHeight))
        // A row opened from elsewhere — a tapped banner — takes the keyboard with
        // it, so the scroller below carries it into view.
        .onChange(of: store.openRowID) { _, id in
            guard let id, let index = visible.firstIndex(where: { $0.id == id }) else { return }
            cursor = index
        }
        .onChange(of: cursor) { _, index in
            guard visible.indices.contains(index) else { return }
            withAnimation(Theme.hover) { scroller.scrollTo(visible[index].id, anchor: .center) }
        }
        }
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        cursor = min(max(0, cursor + delta), visible.count - 1)
    }

    private func openFocused() {
        guard visible.indices.contains(cursor) else { return }
        let row = visible[cursor]
        withAnimation(Theme.expand) {
            store.open(store.openRowID == row.id ? nil : row)
        }
    }

    private func decideFocused(_ allow: Bool) {
        guard visible.indices.contains(cursor) else { return }
        let row = visible[cursor]
        guard case .pending(let p) = row else { return }
        // ⌘↵ on a question would be a decision Claude Code drops; the answer has
        // to be one of the options.
        if p.kind == "question", allow { return }
        if p.kind == "plan", allow { store.approvePlan(row); cursor = min(cursor, max(0, visible.count - 2)); return }
        store.decide(row, allow: allow)
        cursor = min(cursor, max(0, visible.count - 2))
    }

    private func closePanel() {
        NSApplication.shared.keyWindow?.close()
    }

    @ViewBuilder
    private func section(_ group: StateGroup, _ rows: [Row]) -> some View {
        // Empty sections vanish. A panel has no room for a heading over nothing.
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                HStack(spacing: Theme.Space.snug) {
                    Text(group.title)
                        .font(Theme.Font.section)
                        .foregroundStyle(.secondary)
                    Text("\(rows.count)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                }
                .padding(.leading, Theme.Space.gap)

                // One platter per group with hairlines between rows, the way
                // System Settings and every grouped list on the Mac is drawn. A
                // border around each row made a column of boxes; the wash behind
                // the blocked ones made it a dashboard.
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RowCard(row: row, store: store, focused: focusedID == row.id)
                            .id(row.id)
                            .transition(Theme.rowTransition)
                        if index < rows.count - 1 {
                            Divider()
                                .padding(.leading, RowCard.textInset)
                                .transition(.opacity)
                        }
                    }
                }
                .background(Platter())
            }
        }
    }
}

/// Someone typing: three dots, lit in turn.
///
/// The system's own repeating symbol effect draws this, and redraws it every
/// frame for as long as the view exists — panel open or not. Three running rows
/// held a third of a core at rest and made the filter field lag under it. This
/// one steps twice a second, and stops when nobody is looking.
private struct TypingDots: View {
    let running: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: running ? 0.45 : 3600)) { context in
            let step = running ? Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3 : 1
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.accentColor.opacity(index == step ? 1 : 0.35))
                        .frame(width: 4, height: 4)
                }
            }
        }
    }
}

/// The surface a group of rows sits on. Lighter than what is behind it in both
/// appearances, which is how the system draws a grouped list: white on a light
/// window, a lift of a few percent on a dark one. A grey-on-grey fill read as a
/// disabled control in light mode.
private struct Platter: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.platter, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.6))
    }
}

// MARK: - Header

private struct Header: View {
    @Bindable var store: InboxStore
    @Binding var composing: Bool

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Inbox")
                    .font(Theme.Font.title)
                Text(summary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Theme.expand, value: summary)
            }

            Spacer(minLength: Theme.Space.gap)

            if let usage = store.usage.first {
                HStack(spacing: Theme.Space.snug) {
                    UsageRing(label: "5h", percentage: usage.rateLimits?.fiveHour?.usedPercentage,
                              help: Self.ringHelp("5-hour", usage.rateLimits?.fiveHour))
                    UsageRing(label: "7d", percentage: usage.rateLimits?.sevenDay?.usedPercentage,
                              help: Self.ringHelp("7-day", usage.rateLimits?.sevenDay))
                }
                .padding(.trailing, Theme.Space.tight)
            }

            // One paragraph for a dozen sessions. The question nobody can answer
            // by reading rows one at a time.
            IconButton(symbol: store.working ? "hourglass" : "sparkles",
                       help: "What Happened While You Were Away") {
                store.summarise()
            }
            .disabled(store.working)

            IconButton(symbol: composing ? "xmark" : "plus",
                       help: "New Session") {
                withAnimation(Theme.expand) { composing.toggle() }
            }

            // Quit lives where a Mac app keeps it: in a menu, not on a power
            // button nobody expects to find in a panel.
            Menu {
                Button("Claude Inbox \(Bundle.version)") {}.disabled(true)
                Button("Check for Updates…") {
                    if let url = Bundle.releasesURL { NSWorkspace.shared.open(url) }
                }
                Divider()
                Toggle("Name sessions and read turns", isOn: Binding(
                    get: { Spend.enabled },
                    set: { Spend.enabled = $0; store.reload() }))
                Button("\(Spend.todayCount) model calls today") {}
                    .disabled(true)
                Divider()
                if Bridge.bundledInstaller != nil {
                    if store.bridgeInstalled {
                        Button("Reinstall Bridge") { store.installBridge() }
                        Button("Uninstall Bridge…") { confirmUninstall() }
                    } else {
                        Button("Install Bridge") { store.installBridge() }
                    }
                    Divider()
                }
                Button("Quit Claude Inbox") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.top, Theme.Space.wide)
        .padding(.bottom, Theme.Space.gap)
    }

    /// A reading that hides its own staleness is worse than no reading: these only
    /// move while a session is talking.
    private static func ringHelp(_ title: String, _ window: UsageRecord.Window?) -> String {
        guard let used = window?.usedPercentage else {
            return "\(title) limit — nothing measured yet. It only moves while a session is talking."
        }
        var parts = ["\(title) limit — \(Int((100 - min(100, max(0, used))).rounded()))% left"]
        parts.append("\(Int(used.rounded()))% used")
        if let resets = Format.resetsIn(window?.resetsAt) { parts.append(resets) }
        return parts.joined(separator: " · ") + ". Only moves while a session is talking."
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall the bridge?"
        alert.informativeText = "The hooks come out of Claude Code's settings and your status line goes back. Sessions stop reporting in; the app stays."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.installBridge(uninstall: true) }
    }

    /// The one line that answers "what is the state of everything" without
    /// anyone having to count rows.
    private var summary: String {
        var parts: [String] = []
        if !store.waiting.isEmpty { parts.append("\(store.waiting.count) waiting") }
        if !store.answered.isEmpty { parts.append("\(store.answered.count) answered") }
        if !store.running.isEmpty { parts.append("\(store.running.count) running") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }
}

/// A symbol button, for the things the header does: the toolbar button every Mac
/// window has — a bare symbol that gains a quiet rounded fill under the pointer.
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? .primary : .tertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(.primary.opacity(hovering && enabled ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { value in withAnimation(Theme.hover) { hovering = value } }
    }
}

/// Starting a session: what to do, where, and on which account.
private struct NewTask: View {
    @Bindable var store: InboxStore
    @Binding var composing: Bool

    @State private var prompt = ""
    @State private var directory = ""
    @State private var configDir = Accounts.preferred
    @FocusState private var focused: Bool

    private var folders: [String] { Launcher.recentDirectories(from: store.rows) }
    private var accounts: [Accounts.Account] { Accounts.all().filter(\.loggedIn) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            TextField("What should it do?", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .lineLimit(1...5)
                .focused($focused)

            HStack(spacing: Theme.Space.step) {
                Picker("", selection: $directory) {
                    Text("Pick a folder").tag("")
                    ForEach(folders, id: \.self) { folder in
                        Text(Format.shortPath(folder)).tag(folder)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 210)

                if accounts.count > 1 {
                    // Switching is an action on the next session, not on the ones
                    // running: a session is bound to the account it started with.
                    Picker("", selection: $configDir) {
                        ForEach(accounts) { account in
                            Text(account.label).tag(account.configDir)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 120)
                }

                Spacer(minLength: 0)
                Button("Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(prompt.isEmpty || directory.isEmpty || store.working)
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.gap)
        .onAppear {
            focused = true
            if directory.isEmpty { directory = folders.first ?? "" }
        }
    }

    private func start() {
        Accounts.preferred = configDir
        store.launch(prompt: prompt, directory: directory, configDir: configDir)
        prompt = ""
        withAnimation(Theme.expand) { composing = false }
    }
}

/// The digest, or why there isn't one.
private struct DigestBanner: View {
    @Bindable var store: InboxStore

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            Image(systemName: store.problem == nil ? "sparkles" : "exclamationmark.triangle.fill")
                .foregroundStyle(store.problem == nil ? Color.accentColor : .orange)
                .padding(.top, 2)
            if let problem = store.problem {
                Text(problem)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let digest = store.digest {
                MarkdownView(text: digest)
            }
            Spacer(minLength: Theme.Space.step)
            Button { store.clearDigest() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.gap)
    }
}

// MARK: - Row

/// One session. Closed it is a line you scan; open it is the thing you would
/// have gone to the terminal for.
private struct RowCard: View {
    let row: Row
    @Bindable var store: InboxStore
    var focused = false
    @State private var hovering = false
    @State private var answerHeight: CGFloat = 0
    @State private var answerExpanded = false
    @State private var draft = ""
    private static let answerMax: CGFloat = 380

    private var isOpen: Bool { store.openRowID == row.id }
    private var isBlocked: Bool { row.state.isBlocked }

    private var session: SessionRecord? {
        if case .session(let s) = row { return s } else { return nil }
    }
    private var unread: Bool { session?.unread ?? false }
    private var issueURL: URL? { Linear.url(for: session?.issue) }
    /// Ten minutes is where "it will get to me" becomes "it has been sitting".
    private var overdue: Bool { isBlocked && Date().timeIntervalSince1970 - row.ts > 600 }

    private var project: String {
        switch row {
        case .pending(let p): Format.projectName(cwd: p.cwd, fallback: p.sessionId, name: nil)
        case .session(let s): Format.label(s)
        }
    }

    private var subject: String {
        switch row {
        case .pending(let p): return Format.askPhrase(p, max: Limits.subject)
        case .session(let s): return Format.headline(s)
        }
    }

    /// Everything a row can do, on the right click a Mac user reaches for first.
    @ViewBuilder
    private var menu: some View {
        if let s = session {
            if let issueURL {
                Button("Open \(s.issue ?? "Issue") in Linear") { NSWorkspace.shared.open(issueURL) }
            }
            if s.pid != nil {
                Button("Go to Terminal") { Terminal.reveal(pid: s.pid) }
            }
            Divider()
            if let answer = s.lastMessage, !answer.isEmpty {
                Button("Copy Answer") { copy(answer) }
            }
            Button("Copy Resume Command") { copy("claude --resume \(s.sessionId)") }
            if let issue = s.issue { Button("Copy \(issue)") { copy(issue) } }
            if let cwd = s.cwd {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
            }
            // A generated name is a guess; this is where a person overrules it.
            if s.issue == nil {
                Divider()
                Button("Rename…") { rename(s) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func rename(_ s: SessionRecord) {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Shown in the panel, in banners and in the digest."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = Format.label(s)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { store.rename(s.sessionId, to: field.stringValue) }
    }

    /// Where a row's text starts, which is also where the hairline under it does.
    static let textInset: CGFloat = Theme.Space.gap + 20 + Theme.Space.step

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if isOpen { details }
        }
        .background(highlight)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.expand) { store.open(isOpen ? nil : row) }
        }
        .contextMenu { menu }
        .onHover { value in
            withAnimation(Theme.hover) { hovering = value }
        }
        // A row opened again starts at the top of its answer, not where the last
        // reading left it.
        .onChange(of: isOpen) { _, open in if !open { answerExpanded = false } }
    }

    /// The highlight a Mac list draws: a rounded fill inside the platter, quiet
    /// under the pointer and a step stronger where the keyboard is. No border, no
    /// tint — the state is the symbol's job, and a blocked row does not need a
    /// wash behind it to be the first thing in the panel.
    private var highlight: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(.primary.opacity(isOpen ? 0.04 : focused ? 0.09 : hovering ? 0.05 : 0))
            .padding(Theme.Space.tight)
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                    // Which session this is, set the way a mail row sets its
                    // sender: it is what the eye finds first going down a list.
                    if isOpen, let issueURL {
                        // Open, the key is the way to the issue itself.
                        Button(project) { NSWorkspace.shared.open(issueURL) }
                            .buttonStyle(.link)
                            .font(Theme.Font.label)
                            .help("Open in Linear  ⌘L")
                    } else {
                        Text(project)
                            .font(Theme.Font.label)
                            .lineLimit(1)
                    }
                    if case .session(let s) = row, let phase = s.phase {
                        Text(phase)
                            .font(Theme.Font.micro.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule(style: .continuous).fill(.primary.opacity(0.08)))
                    }
                    Spacer(minLength: Theme.Space.tight)
                    Text(Format.age(row.ts))
                        .font(overdue ? Theme.Font.caption.weight(.semibold) : Theme.Font.caption)
                        .foregroundStyle(overdue ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(Theme.shuffle, value: Format.age(row.ts))
                }
                // What it says. A row that wants something, or has an answer to
                // read, is set in the primary colour; one that is only running is
                // weather, and recedes.
                Text(subject)
                    .contentTransition(.opacity)
                    .animation(Theme.shuffle, value: subject)
                    .font(unread ? Theme.Font.subject.weight(.medium) : Theme.Font.subject)
                    .foregroundStyle(row.state.group == .running || (row.state.group == .answered && !unread)
                                     ? .secondary : .primary)
                    .lineLimit(isOpen ? 5 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // The decision is the whole job. It does not hide behind a click.
                if case .pending = row { decision }
            }
        }
        .padding(.horizontal, Theme.Space.gap)
        .padding(.vertical, Theme.Space.step + 1)
    }

    /// The state, as a symbol in the state's colour and nothing else: no tile, no
    /// wash. Each one is a sign the Mac already uses for the same thing — the
    /// three dots of someone typing for a session at work, the blue dot of an
    /// unread message for an answer nobody has opened.
    private var glyph: some View {
        Group {
            if row.state == .working {
                TypingDots(running: store.panelVisible)
            } else if unread {
                Circle().fill(Color.accentColor).frame(width: 9, height: 9)
            } else {
                // The mark in white on the state's colour, the way the system
                // draws a badge; a hierarchical triangle came out as a brown wash.
                Image(systemName: row.state == .idle ? "bubble.left" : row.state.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .symbolRenderingMode(isBlocked ? .palette : .hierarchical)
                    .foregroundStyle(isBlocked ? AnyShapeStyle(.white) : AnyShapeStyle(row.state.tint),
                                     AnyShapeStyle(row.state.tint))
                    // A row that has just started needing you says so once.
                    .symbolEffect(.bounce, value: isBlocked ? row.ts : 0)
            }
        }
        .frame(width: 20, alignment: .center)
        .contentTransition(.symbolEffect(.replace))
        .animation(Theme.expand, value: row.state)
        .animation(Theme.expand, value: unread)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
    }

    /// Claude Code says it plainly: for a tool that answers on its own card,
    /// one-tap Approve must not be offered — a bare allow for it is dropped, so a
    /// button that looks like it works would do nothing at all.
    private var answersOnCard: Bool {
        if case .pending(let p) = row { return p.kind == "question" || p.kind == "plan" }
        return false
    }

    private var decision: some View {
        HStack(spacing: Theme.Space.snug) {
            if case .pending(let p) = row, p.kind == "question" {
                // Nothing to approve: the options below are the answer. Claude
                // Code is explicit that a one-tap Approve must not be offered for
                // a tool that answers on its own card, and a button that looks
                // like it works while doing nothing is the worst of both.
                Button("Dismiss") { store.decide(row, allow: false) }
                    .buttonStyle(.bordered)
            } else if case .pending(let p) = row, p.kind == "plan" {
                Button("Approve plan") { store.approvePlan(row) }
                    .buttonStyle(.borderedProminent)
                Button("Reject") { store.decide(row, allow: false) }
                    .buttonStyle(.bordered)
            } else {
                Button("Approve") { store.decide(row, allow: true) }
                    .buttonStyle(.borderedProminent)
                Button("Deny") { store.decide(row, allow: false) }
                    .buttonStyle(.bordered)
                // Answering the same question twelve times is the thing worth
                // fixing, and Claude Code already says what the broader answer
                // would be. A menu rather than three more buttons: this is the
                // rarer press, and the one you should read before making.
                if case .pending(let item) = row {
                    let grants = Format.grants(item)
                    if !grants.isEmpty {
                        Menu("Allow and…") {
                            ForEach(grants) { grant in
                                Button(grant.label) { store.decide(row, allow: true, grant: grant) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Approve, and let Claude Code stop asking")
                    }
                }
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.top, Theme.Space.tight)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gap) {
            if case .pending(let item) = row { ask(for: item) }

            if case .session(let s) = row {
                if let asked = Format.userPrompt(s.lastPrompt) {
                    // What was asked, set as a quotation — the way Mail sets the
                    // message being replied to.
                    HStack(alignment: .top, spacing: Theme.Space.step) {
                        RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 2)
                        Text(Format.oneLine(asked))
                            .font(Theme.Font.subject)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                // The whole answer. Truncating this is what kept sending people
                // back to the terminal.
                if let answer = store.narration ?? s.lastMessage, !answer.isEmpty {
                    // Never a scroll view inside a scroll view. One nested here
                    // ate the wheel and would not hand it back: with the pointer
                    // over a long answer the panel could not be scrolled at all,
                    // and an open row became a dead end. A long answer is capped
                    // and opened in place instead; the panel's own scroller stays
                    // the only one.
                    let overflowing = answerHeight > Self.answerMax
                    let capped = overflowing && !answerExpanded
                    MarkdownView(text: answer)
                        .measureHeight(into: $answerHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: capped ? Self.answerMax : nil, alignment: .top)
                        .clipped()
                        // Cut through a line reads as broken; fading out reads as
                        // "there is more", which is what the button then offers.
                        .mask(
                            LinearGradient(
                                stops: [.init(color: .black, location: 0),
                                        .init(color: .black, location: capped ? 0.86 : 1),
                                        .init(color: capped ? .clear : .black, location: 1)],
                                startPoint: .top, endPoint: .bottom))
                    if overflowing {
                        Button(answerExpanded ? "Show less" : "Show more") {
                            withAnimation(Theme.expand) { answerExpanded.toggle() }
                        }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                    }
                }
                if !store.activity.isEmpty {
                    // These are sentences now — the model's own description of
                    // each command — so they are set as text, not as a log.
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(store.activity.prefix(4), id: \.self) { line in
                            Text(line)
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            replies
            composer
            footer
        }
        // The full width of the card, not the column under the label: an answer
        // is read, and thirty points of indent cost it a sixth of every line.
        .padding(.horizontal, Theme.Space.wide)
        .padding(.top, Theme.Space.tight)
        .padding(.bottom, Theme.Space.gap)
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.gap) {
            if let cwd = row.cwd {
                Text(Format.shortPath(cwd))
                    .font(Theme.Font.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            Spacer(minLength: Theme.Space.step)
            // The way back into a session without hunting for the window it
            // started in.
            CopyButton(text: "claude --resume \(row.sessionId)", label: "Copy Resume Command")
                .fixedSize()
            if let pid = session?.pid {
                Button("Go to Terminal") { Terminal.reveal(pid: pid) }
                    .buttonStyle(.link)
                    .font(Theme.Font.caption)
                    .fixedSize()
                    .help("Bring the session's terminal forward  ⌘T")
            }
        }
    }

    /// The answers a person is most likely to give, one tap from the draft. A
    /// tap fills the field and stops there: an approval sent by a stray click is
    /// a decision nobody made.
    @ViewBuilder
    private var replies: some View {
        if let s = session, !s.replies.isEmpty, let pid = s.pid, Peer.canReach(pid: pid) {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.snug) {
                    ForEach(s.replies, id: \.self) { reply in
                        Button(reply) { draft = reply }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Writing back into a session that is still running.
    @ViewBuilder
    private var composer: some View {
        if case .session(let s) = row, let pid = s.pid, Peer.canReach(pid: pid) {
            Composer(pid: pid, permissionMode: s.permissionMode, awaitingDecision: s.needsYou,
                     text: $draft, onSent: { store.reload() })
        }
    }

    /// What is actually being decided.
    ///
    /// The first version printed whatever string it could find, which for a file
    /// edit meant two lines of `/private/var/folders/sz/…` — a path nobody reads
    /// and nobody decides on. A command is the decision; a file is its name, with
    /// the directory kept small beside it.
    @ViewBuilder
    private func ask(for item: PendingItem) -> some View {
        if item.kind == "question" {
            QuestionForm(item: item, store: store, row: row)
        } else if item.kind == "plan", let plan = item.toolInput?["plan"]?.stringValue, !plan.isEmpty {
            // A plan is read before it is approved, so it is set like an answer
            // rather than like a command.
            MarkdownView(text: plan)
        } else if let command = item.toolInput?["command"]?.stringValue {
            Text(command)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .lineLimit(6)
                .padding(Theme.Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .fill(.primary.opacity(0.06)))
        } else if let path = item.toolInput?["file_path"]?.stringValue {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(path.split(separator: "/").last.map(String.init) ?? path)
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                Text(Format.shortPath((path as NSString).deletingLastPathComponent))
                    .font(Theme.Font.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .fill(.primary.opacity(0.06)))
        }
    }

}

/// A line you can type into a running session.
///
/// Honest about what it is: Claude Code renders anything arriving this way as
/// *"Another Claude session sent a message"*, with a preamble telling the session
/// to treat the sender as a teammate rather than as its user. There is no mode
/// that says otherwise, and there should not be — nothing outside the terminal
/// should be able to impersonate the person at it. So this is a nudge, and the
/// placeholder says so rather than letting anyone find out later.
private struct Composer: View {
    let pid: Int
    let permissionMode: String?
    /// The session's last turn ended by asking the person for a decision. A note
    /// cannot carry that decision, and saying so here beats finding out later.
    var awaitingDecision = false
    @Binding var text: String
    let onSent: () -> Void

    @State private var problem: String?
    @State private var sent = false
    @State private var held = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.snug) {
                TextField("Send a note to this session…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: sent ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(sent ? AnyShapeStyle(Color.green)
                                              : AnyShapeStyle(text.isEmpty ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                                                           : AnyShapeStyle(Color.accentColor)))
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
            }
            .padding(.leading, Theme.Space.gap)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            // The field Messages has: a hairline capsule with the send button
            // inside it, and the system's own focus colour when it is live.
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(focused ? AnyShapeStyle(Color.accentColor.opacity(0.7))
                                          : AnyShapeStyle(Color(nsColor: .separatorColor)),
                                  lineWidth: 1))

            if let problem {
                Text(problem)
                    .font(Theme.Font.micro)
                    .foregroundStyle(.orange)
            } else if held {
                // Saying this after the fact would be worse than not saying it:
                // the whole point is not having to go to the terminal, and a held
                // message is a trip to the terminal with extra steps.
                HStack(alignment: .top, spacing: Theme.Space.snug) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.micro)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This session bypasses prompts, so Claude Code parks notes from outside it. You would have to release this one in the terminal.")
                            .font(Theme.Font.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Deliver Them Instead") { accept() }
                            .buttonStyle(.link)
                            .font(Theme.Font.micro)
                            .help("Sets crossSessionInbound to \"accept\". Anything on this machine running as you could then steer a bypassing session. Your settings.json is backed up first.")
                    }
                }
            } else {
                HStack(spacing: Theme.Space.snug) {
                    // Claude Code frames anything arriving from outside the
                    // terminal as a peer message, on purpose: nothing else on the
                    // machine should be able to speak with your authority. It is
                    // a nudge, and it is worth saying which kind.
                    Text(awaitingDecision
                         ? "Signed as yours, but still a peer's note — steering, not approval."
                         : "Arrives signed as typed by you, as a message from a peer session.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(.tertiary)
                    // When it has to be you saying it, the shortest honest path is
                    // the clipboard and the terminal it is already running in.
                    Button("Say it yourself") {
                        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !note.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note, forType: .string)
                        }
                        Terminal.reveal(pid: pid)
                    }
                    .buttonStyle(.link)
                    .font(Theme.Font.micro)
                    .help("Copy the note and bring the session's terminal forward — paste it there and it is you talking")
                    Spacer(minLength: 0)
                }
                .padding(.leading, Theme.Space.gap)
            }
        }
        .onAppear { held = Settings.willHold(permissionMode: permissionMode) }
    }

    private func accept() {
        if Settings.setInbound(.accept) {
            held = false
        } else {
            problem = "Could not write settings.json — it may be unreadable."
        }
    }

    private func send() {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        do {
            try Peer.send(note, toPID: pid)
            text = ""
            problem = nil
            withAnimation(Theme.hover) { sent = true }
            onSent()
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(Theme.hover) { sent = false }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct CopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Theme.hover) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(Theme.hover) { copied = false }
            }
        } label: {
            Text(copied ? "Copied" : label)
        }
        .buttonStyle(.link)
        .font(Theme.Font.caption)
    }
}

// MARK: - Furniture

/// The system's own empty state, so that "nothing here" looks the way it does in
/// Mail, in Finder and in every other window on the machine.
private struct Placeholder: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if !detail.isEmpty { Text(detail) }
        } actions: {
            if let (label, act) = action {
                Button(label, action: act)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, Theme.Space.tight)
            }
        }
        .padding(.vertical, Theme.Space.room)
    }
}

private struct Footer: View {
    let usage: UsageRecord

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Text(line)
                .font(Theme.Font.micro)
                .foregroundStyle(.tertiary)
            Spacer()
            if let cost = usage.cost?.totalCostUsd, cost > 0 {
                Text(String(format: "$%.2f", cost))
                    .font(Theme.Font.micro)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.step)
    }

    /// A reading that hides its own staleness is worse than no reading: it only
    /// moves while a session is talking.
    private var line: String {
        let soonest = [usage.rateLimits?.fiveHour?.resetsAt, usage.rateLimits?.sevenDay?.resetsAt]
            .compactMap { $0 }.min()
        var parts: [String] = []
        if let reset = Format.resetsIn(soonest) { parts.append(reset) }
        parts.append("read \(Format.age(usage.ts))")
        if let model = usage.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

/// Answering a question without the terminal.
///
/// One tap on an option answers a single-choice question, because that is the
/// whole point — the round trip this removes is measured in minutes. A
/// multi-select gathers first and sends once. Free text rides in the same
/// `answers` map, in the slot Claude Code leaves for it.
private struct QuestionForm: View {
    let item: PendingItem
    @Bindable var store: InboxStore
    let row: Row

    @State private var chosen: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    private var asked: [Format.Asked] { Format.asked(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gap) {
            ForEach(asked) { q in
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    // With one question the card's headline already said it.
                    if asked.count > 1 {
                        Text(q.question)
                            .font(Theme.Font.reading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(q.options, id: \.self) { option in
                        Button { pick(q, option) } label: {
                            HStack(spacing: Theme.Space.snug) {
                                Image(systemName: mark(q, option))
                                    .foregroundStyle(picked(q, option) ? AnyShapeStyle(Color.accentColor)
                                                                       : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                                    .contentTransition(.symbolEffect(.replace))
                                Text(option)
                                    .font(Theme.Font.reading)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(OptionButton())
                        .animation(Theme.hover, value: picked(q, option))
                    }
                    TextField("Something else…", text: binding(for: q), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.reading)
                        .lineLimit(1...4)
                        .padding(.horizontal, Theme.Space.step)
                        .padding(.vertical, Theme.Space.snug)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                                .fill(.primary.opacity(0.06)))
                        .onSubmit(send)
                }
            }
            // A single choice with nothing typed has already been sent by the tap.
            if needsSend {
                Button("Send answer") { send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(gathered.isEmpty)
            }
        }
    }

    private var needsSend: Bool {
        asked.contains { $0.multiSelect } || typed.values.contains { !$0.isEmpty }
    }

    private func picked(_ q: Format.Asked, _ option: String) -> Bool {
        chosen[q.question]?.contains(option) ?? false
    }

    private func mark(_ q: Format.Asked, _ option: String) -> String {
        let on = picked(q, option)
        if q.multiSelect { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }

    private func binding(for q: Format.Asked) -> Binding<String> {
        Binding(get: { typed[q.question] ?? "" }, set: { typed[q.question] = $0 })
    }

    private func pick(_ q: Format.Asked, _ option: String) {
        if q.multiSelect {
            var set = chosen[q.question] ?? []
            if set.contains(option) { set.remove(option) } else { set.insert(option) }
            chosen[q.question] = set
            return
        }
        chosen[q.question] = [option]
        // One question, one choice, nothing typed: the tap was the answer.
        if asked.count == 1, (typed[q.question] ?? "").isEmpty { send() }
    }

    /// What the person has actually said, in the order the options were offered
    /// so a multi-select reads the way it was drawn.
    private var gathered: [String: [String]] {
        var out: [String: [String]] = [:]
        for q in asked {
            var values = q.options.filter { chosen[q.question]?.contains($0) ?? false }
            let free = (typed[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !free.isEmpty {
                if q.multiSelect { values.append(free) } else { values = [free] }
            }
            if !values.isEmpty { out[q.question] = values }
        }
        return out
    }

    private func send() {
        let answers = gathered
        guard answers.count == asked.count else { return }  // every question, or none
        store.answer(row, answers: answers)
    }
}
