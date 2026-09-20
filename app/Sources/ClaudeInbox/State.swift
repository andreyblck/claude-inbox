import SwiftUI

/// The state vocabulary, shared by `bridge/` and every surface.
///
/// Ported from `spec/lib/state.ts`, which is the specification: the rules there
/// have tests, and this has to agree with them. Nothing renders a state that is
/// not in this enum.
enum InboxState: String, Codable, Sendable, CaseIterable {
    case blockedPermission = "blocked.permission"
    case blockedQuestion = "blocked.question"
    case blockedPlan = "blocked.plan"
    case blockedDialog = "blocked.dialog"
    case working
    case idle
    case done
    case failed

    /// Unknown states come from a newer bridge. Render them as running — never as
    /// something that needs the human, because inventing urgency is the one error
    /// this vocabulary exists to prevent.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InboxState(rawValue: raw) ?? .working
    }
}

/// The four questions a person brings to this app, in the order they ask them.
enum StateGroup: Int, Comparable, Sendable, CaseIterable {
    case waiting = 0
    case answered = 1
    case running = 2
    case finished = 3

    var title: String {
        switch self {
        case .waiting: "Waiting for you"
        case .answered: "Answered"
        case .running: "Running"
        case .finished: "Recently finished"
        }
    }

    static func < (a: StateGroup, b: StateGroup) -> Bool { a.rawValue < b.rawValue }
}

extension InboxState {
    var group: StateGroup {
        switch self {
        case .blockedPermission, .blockedQuestion, .blockedPlan, .blockedDialog: .waiting
        // A finished turn is not the same quiet as a busy one: the session said
        // something and is waiting for it to be read.
        case .idle: .answered
        case .working: .running
        case .done, .failed: .finished
        }
    }

    /// Sentence-case, and never the row's only content — the glyph says it too.
    var label: String {
        switch self {
        case .blockedPermission: "Permission"
        case .blockedQuestion: "Question"
        case .blockedPlan: "Plan"
        case .blockedDialog: "Needs terminal"
        case .working: "Working"
        case .idle: "Answered"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    /// Sort key inside a group: lower comes first.
    var rank: Int {
        switch self {
        case .blockedPermission: 0
        case .blockedQuestion: 1
        case .blockedPlan: 2
        case .blockedDialog: 3
        case .working, .idle, .done: 0
        case .failed: 1
        }
    }

    /// States differ by shape, not only by colour — the menu bar is monochrome
    /// and a colour-blind reader is not a special case.
    var symbol: String {
        switch self {
        case .blockedPermission: "lock.fill"
        case .blockedQuestion: "questionmark.circle.fill"
        case .blockedPlan: "list.bullet.rectangle.fill"
        case .blockedDialog: "exclamationmark.triangle.fill"
        case .working: "circle.fill"
        case .idle: "bubble.left.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .blockedPermission, .blockedQuestion, .blockedPlan: .yellow
        // Trust and MCP dialogs cannot be answered anywhere but the terminal, so
        // they are orange, not yellow: the only useful action is "take me there".
        case .blockedDialog: .orange
        case .working: .blue
        case .idle: .secondary
        case .done: .green
        case .failed: .red
        }
    }

    var isBlocked: Bool { group == .waiting }
}

/// Hard caps. Exceeding one is a design bug, not a display detail.
enum Limits {
    /// Characters of project name anywhere.
    static let project = 24
    /// Characters of the "what it wants" phrase for a blocked session.
    static let ask = 40
    /// Characters of what a running session is *about*. Longer than `ask` on
    /// purpose: "run rm -rf dist" says everything in 15, while a real subject is
    /// the whole value of the row.
    static let subject = 80
}
