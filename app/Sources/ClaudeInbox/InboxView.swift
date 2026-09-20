import SwiftUI

/// The panel. This is what a menu row could not be and why the app exists: a
/// card you open and read the whole answer in, with the decision on that card.
struct InboxView: View {
    @Bindable var store: InboxStore
    @State private var contentHeight: CGFloat = 0
    @State private var composing = false

    var body: some View {
        VStack(spacing: 0) {
            Header(store: store, composing: $composing)
            Divider().opacity(0.5)

            if composing {
                NewTask(store: store, composing: $composing)
                Divider().opacity(0.5)
            }
            if store.digest != nil || store.problem != nil {
                DigestBanner(store: store)
                Divider().opacity(0.5)
            }

            Group {
                if !store.bridgeInstalled {
                    Placeholder(
                        symbol: "powerplug",
                        tint: .orange,
                        title: "The bridge is not installed",
                        // A quiet machine and a disconnected one look identical
                        // to a reader. Say which one this is.
                        detail: "Run bridge/install.sh once. Until then nothing reports in.")
                } else if store.rows.isEmpty {
                    Placeholder(
                        symbol: "checkmark.circle",
                        tint: .green,
                        title: "Nothing needs you",
                        detail: "Sessions appear the moment one blocks on a decision.")
                } else {
                    list
                }
            }

            if let account = store.usage.first {
                Divider().opacity(0.5)
                Footer(usage: account)
            }
        }
        .frame(width: Theme.panelWidth)
        .background(VisualEffect())
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.wide) {
                section(.waiting, store.waiting)
                section(.answered, store.answered)
                section(.running, store.running)
                section(.finished, store.finished)
            }
            .padding(.horizontal, Theme.Space.gap)
            .padding(.vertical, Theme.Space.gap)
            // Fill the panel, do not restate its width: this stack carries the
            // horizontal padding, so naming the same number here makes it wider
            // than its own parent.
            .frame(maxWidth: .infinity, alignment: .leading)
            .measureHeight(into: $contentHeight)
        }
        .scrollIndicators(.never)
        // As short as one row, never taller than the panel is allowed to be.
        .frame(height: min(max(contentHeight, 1), Theme.panelMaxHeight))
    }

    @ViewBuilder
    private func section(_ group: StateGroup, _ rows: [Row]) -> some View {
        // Empty sections vanish. A panel has no room for a heading over nothing.
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                HStack(spacing: Theme.Space.snug) {
                    Text(group.title.uppercased())
                        .font(Theme.Font.section)
                        .tracking(0.9)
                        .foregroundStyle(group == .waiting
                                         ? AnyShapeStyle(Color.yellow.opacity(0.9))
                                         : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    Text("\(rows.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.quaternary)
                    Spacer()
                }
                .padding(.leading, Theme.Space.tight)

                VStack(spacing: Theme.Space.snug) {
                    ForEach(rows) { row in
                        RowCard(row: row, store: store)
                    }
                }
            }
        }
    }
}

// MARK: - Header

private struct Header: View {
    @Bindable var store: InboxStore
    @Binding var composing: Bool
    @State private var hoveringQuit = false

    var body: some View {
        HStack(spacing: Theme.Space.step) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Inbox")
                    .font(Theme.Font.title)
                Text(summary)
                    .font(Theme.Font.micro)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Theme.Space.gap)

            // One paragraph for a dozen sessions. The question nobody can answer
            // by reading rows one at a time.
            IconButton(symbol: store.working ? "hourglass" : "sparkles",
                       help: "What happened while you were away") {
                store.summarise()
            }
            .disabled(store.working)

            IconButton(symbol: composing ? "xmark" : "plus",
                       help: "Start a session without a terminal") {
                withAnimation(Theme.expand) { composing.toggle() }
            }

            if let usage = store.usage.first {
                HStack(spacing: Theme.Space.snug) {
                    UsageRing(label: "5h", percentage: usage.rateLimits?.fiveHour?.usedPercentage)
                    UsageRing(label: "7d", percentage: usage.rateLimits?.sevenDay?.usedPercentage)
                }
                .help("Rate limits. They only move while a session is talking.")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hoveringQuit ? AnyShapeStyle(Color.primary)
                                                  : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
            .buttonStyle(.plain)
            .help("Quit Claude Inbox")
            .onHover { hovering in
                withAnimation(Theme.hover) { hoveringQuit = hovering }
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.gap)
    }

    /// The one line that answers "what is the state of everything" without
    /// anyone having to count rows.
    private var summary: String {
        var parts: [String] = []
        if !store.waiting.isEmpty { parts.append("\(store.waiting.count) waiting") }
        if !store.answered.isEmpty { parts.append("\(store.answered.count) answered") }
        if !store.running.isEmpty { parts.append("\(store.running.count) running") }
        return parts.isEmpty ? "all quiet" : parts.joined(separator: " · ")
    }
}

/// A small square button, for the things the header does.
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(Color.primary)
                                          : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(.primary.opacity(hovering ? 0.1 : 0.05)))
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
                .font(.system(size: 11))
                .foregroundStyle(store.problem == nil ? Color.accentColor : .orange)
                .padding(.top, 1)
            if let problem = store.problem {
                Text(problem)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let digest = store.digest {
                MarkdownView(text: digest)
            }
            Spacer(minLength: Theme.Space.step)
            IconButton(symbol: "xmark", help: "Dismiss") { store.clearDigest() }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.gap)
        .background(Color.accentColor.opacity(store.problem == nil ? 0.07 : 0))
    }
}

// MARK: - Row

/// One session. Closed it is a line you scan; open it is the thing you would
/// have gone to the terminal for.
private struct RowCard: View {
    let row: Row
    @Bindable var store: InboxStore
    @State private var hovering = false

    private var isOpen: Bool { store.openRowID == row.id }
    private var isBlocked: Bool { row.state.isBlocked }

    private var project: String {
        switch row {
        case .pending(let p): Format.projectName(cwd: p.cwd, fallback: p.sessionId, name: nil)
        case .session(let s): Format.projectName(cwd: s.cwd, fallback: s.sessionId, name: s.name)
        }
    }

    private var subject: String {
        switch row {
        case .pending(let p): Format.askPhrase(p)
        // A dialog the terminal owns says what it wants; that beats what we infer.
        case .session(let s): s.waitingFor ?? Format.subject(s)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if isOpen { details }
        }
        .background(background)
        .overlay(alignment: .leading) {
            // A blocked row is the only thing in this panel that is *about* you.
            // The accent says so before any word is read.
            if isBlocked {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(row.state.tint)
                    .frame(width: 3)
                    .padding(.vertical, Theme.Space.step)
                    .padding(.leading, Theme.Space.tight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.expand) { store.open(isOpen ? nil : row) }
        }
        .onHover { value in
            withAnimation(Theme.hover) { hovering = value }
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(isBlocked
                  ? AnyShapeStyle(row.state.tint.opacity(hovering ? 0.18 : 0.13))
                  : AnyShapeStyle(Color.primary.opacity(hovering || isOpen ? 0.085 : 0.05)))
            .overlay(
                // A hairline is what separates a card from a wash. Without it a
                // column of fills reads as one grey block with text in it.
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        isBlocked ? row.state.tint.opacity(0.3) : Color.primary.opacity(0.07),
                        lineWidth: 0.5))
    }

    private var head: some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            glyph
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.snug) {
                    // Which session this is. The cheapest question on the card,
                    // so it takes the smallest type on it.
                    Text(project.uppercased())
                        .font(Theme.Font.eyebrow)
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if case .session(let s) = row, let phase = s.phase {
                        Text(phase)
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(row.state.tint.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                    .fill(row.state.tint.opacity(0.14)))
                    }
                    Spacer(minLength: Theme.Space.tight)
                    Text(Format.age(row.ts))
                        .font(Theme.Font.micro)
                        .foregroundStyle(.quaternary)
                        .monospacedDigit()
                }
                // The headline: what is going on. The first version gave this
                // less weight than the project name, so every card led with the
                // least interesting thing on it.
                Text(subject)
                    .font(Theme.Font.subject)
                    .foregroundStyle(.primary)
                    .lineLimit(isOpen ? 5 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // The decision is the whole job. It does not hide behind a click.
                if case .pending = row { decision }
            }
        }
        .padding(.horizontal, Theme.Space.gap)
        .padding(.vertical, Theme.Space.step + 2)
        .padding(.leading, isBlocked ? Theme.Space.tight : 0)
    }

    private var glyph: some View {
        Image(systemName: row.state.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(row.state.tint)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(row.state.tint.opacity(0.14)))
            .padding(.top, 1)
    }

    private var decision: some View {
        HStack(spacing: Theme.Space.snug) {
            Button("Approve") { store.decide(row, allow: true) }
                .buttonStyle(.borderedProminent)
                .tint(row.state.tint)
            Button("Deny") { store.decide(row, allow: false) }
                .buttonStyle(.bordered)
            Spacer()
        }
        .controlSize(.small)
        .padding(.top, Theme.Space.tight)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            Divider().opacity(0.4)

            if case .pending(let item) = row { ask(for: item) }

            if case .session(let s) = row {
                if let asked = Format.userPrompt(s.lastPrompt) {
                    HStack(alignment: .top, spacing: Theme.Space.step) {
                        RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 2)
                        Text(Format.oneLine(asked))
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                    }
                }
                // The whole answer. Truncating this is what kept sending people
                // back to the terminal.
                if let answer = store.narration ?? s.lastMessage, !answer.isEmpty {
                    ScrollView {
                        MarkdownView(text: answer)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 300)
                }
                if !store.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.activity.prefix(4), id: \.self) { line in
                            Text(line)
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(.quaternary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            composer
            footer
        }
        .padding(.horizontal, Theme.Space.gap)
        .padding(.bottom, Theme.Space.gap)
        .padding(.leading, isBlocked ? Theme.Space.tight : 0)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.step) {
            if let cwd = row.cwd {
                Text(Format.shortPath(cwd))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Theme.Space.step)
            // The way back into a session without hunting for the window it
            // started in.
            CopyButton(text: "claude --resume \(row.sessionId)", label: "Resume")
            if let cwd = row.cwd {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                } label: {
                    Text("Folder").font(.system(size: 9.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
    }

    /// Writing back into a session that is still running.
    @ViewBuilder
    private var composer: some View {
        if case .session(let s) = row, let pid = s.pid, Peer.canReach(pid: pid) {
            Composer(pid: pid, permissionMode: s.permissionMode, onSent: { store.reload() })
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
        if let command = item.toolInput?["command"]?.stringValue {
            Text(command)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .lineLimit(6)
                .padding(Theme.Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(.black.opacity(0.22)))
        } else if let path = item.toolInput?["file_path"]?.stringValue {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(path.split(separator: "/").last.map(String.init) ?? path)
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                Text(Format.shortPath((path as NSString).deletingLastPathComponent))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(.black.opacity(0.22)))
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
    let onSent: () -> Void

    @State private var text = ""
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
                    Image(systemName: sent ? "checkmark" : "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(sent ? AnyShapeStyle(Color.green)
                                              : AnyShapeStyle(text.isEmpty ? AnyShapeStyle(HierarchicalShapeStyle.quaternary)
                                                                           : AnyShapeStyle(Color.accentColor)))
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .strokeBorder(focused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)))

            if let problem {
                Text(problem)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            } else if held {
                // Saying this after the fact would be worse than not saying it:
                // the whole point is not having to go to the terminal, and a held
                // message is a trip to the terminal with extra steps.
                HStack(alignment: .top, spacing: Theme.Space.snug) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This session bypasses prompts, so Claude Code parks notes from outside it. You would have to release this one in the terminal.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Deliver them instead") { accept() }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Sets crossSessionInbound to \"accept\". Anything on this machine running as you could then steer a bypassing session. Your settings.json is backed up first.")
                    }
                }
            } else {
                Text("Arrives as a message from a peer session, not as you.")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
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
                .font(.system(size: 9.5, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? AnyShapeStyle(Color.green)
                                : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
    }
}

// MARK: - Furniture

private struct Placeholder: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Theme.Space.step) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(tint.opacity(0.85))
            Text(title)
                .font(Theme.Font.body.weight(.medium))
            Text(detail)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.room * 2)
        .padding(.horizontal, Theme.Space.room)
    }
}

private struct Footer: View {
    let usage: UsageRecord

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Text(line)
                .font(.system(size: 9.5))
                .foregroundStyle(.quaternary)
            Spacer()
            if let cost = usage.cost?.totalCostUsd, cost > 0 {
                Text(String(format: "$%.2f", cost))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.quaternary)
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
