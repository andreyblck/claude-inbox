import SwiftUI

/// The panel. This is what Raycast could not render and why the app exists: a
/// card you can open and read an answer in, with the decision on the same card.
struct InboxView: View {
    @Bindable var store: InboxStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.bridgeInstalled {
                notInstalled
            } else if store.rows.isEmpty {
                empty
            } else {
                list
            }
            if let account = store.usage.first {
                Divider()
                UsageBar(usage: account)
            }
        }
        .frame(width: 460)
        .frame(maxHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
            Text("Claude Inbox")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !store.waiting.isEmpty {
                Text("\(store.waiting.count) waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.yellow)
            }
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Claude Inbox")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                section(.waiting, store.waiting)
                section(.answered, store.answered)
                section(.running, store.running)
                section(.finished, store.finished)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func section(_ group: StateGroup, _ rows: [Row]) -> some View {
        // Empty sections vanish. A panel has no room for placeholders saying
        // nothing is here.
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(group.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                ForEach(rows) { row in
                    RowCard(row: row, store: store)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.green.opacity(0.8))
            Text("Nothing needs you")
                .font(.system(size: 13, weight: .medium))
            Text("Sessions appear the moment one blocks on a decision.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var notInstalled: some View {
        VStack(spacing: 8) {
            Image(systemName: "powerplug")
                .font(.system(size: 28))
                .foregroundStyle(.orange.opacity(0.9))
            Text("The bridge is not installed")
                .font(.system(size: 13, weight: .medium))
            // A quiet machine and a disconnected one look identical; say which.
            Text("Run bridge/install.sh once. Until then nothing reports in.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }
}

/// One session, openable. Closed it is a line you scan; open it is the thing you
/// would have gone to the terminal for.
private struct RowCard: View {
    let row: Row
    @Bindable var store: InboxStore
    @State private var hovering = false

    private var isOpen: Bool { store.openRowID == row.id }

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
            Button {
                store.open(isOpen ? nil : row)
            } label: {
                head
            }
            .buttonStyle(.plain)

            if isOpen {
                expanded(for: row)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(.quaternary.opacity(hovering || isOpen ? 0.55 : 0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(row.state.isBlocked ? row.state.tint.opacity(0.35) : .clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }

    private var head: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: row.state.symbol)
                .font(.system(size: 11))
                .foregroundStyle(row.state.tint)
                .frame(width: 14, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // A column of short names is what the eye scans; the sentence
                    // beside it is read only on the row it stopped at.
                    Text(project)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if case .session(let s) = row, let phase = s.phase {
                        Text(phase)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary.opacity(0.7)))
                    }
                    Spacer(minLength: 4)
                    Text(Format.age(row.ts))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(subject)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(isOpen ? 3 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func expanded(for row: Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if case .pending(let item) = row {
                if let command = item.toolInput?["command"]?.stringValue
                    ?? item.toolInput?["file_path"]?.stringValue
                {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.22)))
                }
                // The decision lives on the card. Going somewhere else to answer
                // is the round trip this is here to remove.
                HStack(spacing: 8) {
                    Button("Approve") { store.decide(row, allow: true) }
                        .keyboardShortcut(.defaultAction)
                    Button("Deny") { store.decide(row, allow: false) }
                    Spacer()
                }
            }

            if case .session(let s) = row {
                if let asked = s.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Rectangle().fill(.tertiary).frame(width: 2)
                        Text(Format.oneLine(asked))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                // The whole answer. Truncating this is what kept sending people
                // back to the terminal.
                if let answer = store.narration ?? s.lastMessage, !answer.isEmpty {
                    ScrollView {
                        Text(markdown(answer))
                            .font(.system(size: 11.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 260)
                }
                if !store.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RECENTLY")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(store.activity.prefix(5), id: \.self) { line in
                            Text("· " + line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if let cwd = row.cwd {
                HStack(spacing: 10) {
                    Text(cwd)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude --resume \(row.sessionId)", forType: .string)
                    } label: {
                        Text("Copy resume")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }
        }
    }

    /// SwiftUI renders inline markdown but not tables, so a table arrives as its
    /// own source. Readable, not right — a real renderer is its own slice.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct UsageBar: View {
    let usage: UsageRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            // A reading that hides its own staleness is worse than no reading: it
            // only moves while a session is talking.
            Text(line)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var line: String {
        var parts: [String] = []
        if let five = usage.rateLimits?.fiveHour?.usedPercentage { parts.append("5h \(Int(five))%") }
        if let week = usage.rateLimits?.sevenDay?.usedPercentage { parts.append("7d \(Int(week))%") }
        if parts.isEmpty { parts.append("no limit data") }
        let soonest = [usage.rateLimits?.fiveHour?.resetsAt, usage.rateLimits?.sevenDay?.resetsAt]
            .compactMap { $0 }.min()
        if let reset = Format.resetsIn(soonest) { parts.append(reset) }
        parts.append(Format.age(usage.ts))
        return parts.joined(separator: " · ")
    }
}
