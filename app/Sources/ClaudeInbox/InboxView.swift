import SwiftUI

/// The panel. This is what a menu row could not be and why the app exists: a
/// card you open and read the whole answer in, with the decision on that card.
struct InboxView: View {
    @Bindable var store: InboxStore
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Header(store: store)
            Divider().opacity(0.5)

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
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
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
                  ? AnyShapeStyle(row.state.tint.opacity(hovering ? 0.16 : 0.11))
                  : AnyShapeStyle(Color.primary.opacity(hovering || isOpen ? 0.07 : 0.04)))
    }

    private var head: some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            glyph
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.snug) {
                    // A column of short names is what the eye scans; the sentence
                    // beside it is read only on the row it stopped at.
                    Text(project)
                        .font(Theme.Font.row)
                        .lineLimit(1)
                    if case .session(let s) = row, let phase = s.phase {
                        Text(phase)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                    .fill(.primary.opacity(0.08)))
                    }
                    Spacer(minLength: Theme.Space.tight)
                    Text(Format.age(row.ts))
                        .font(Theme.Font.micro)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(subject)
                    .font(Theme.Font.caption)
                    .foregroundStyle(isBlocked ? AnyShapeStyle(Color.primary)
                                               : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(isOpen ? 4 : 2)
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

            if case .pending(let item) = row,
               let command = item.toolInput?["command"]?.stringValue
                   ?? item.toolInput?["file_path"]?.stringValue
            {
                Text(command)
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                    .padding(Theme.Space.step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(.black.opacity(0.2)))
            }

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
                        Text(markdown(answer))
                            .font(Theme.Font.body)
                            .textSelection(.enabled)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 280)
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
                Text(cwd)
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

    /// SwiftUI renders inline markdown but not tables, so a table arrives as its
    /// own source. Readable, not right — a real renderer is its own slice.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
