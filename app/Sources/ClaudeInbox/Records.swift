import Foundation

/// The shapes `bridge/` writes. Every field is optional on purpose: a record is
/// written by a shell script from a payload we do not control, and a missing
/// field must degrade a row rather than drop it.
struct PendingItem: Codable, Sendable, Identifiable {
    var req: String
    var kind: String?
    var state: InboxState
    var ts: Double
    var sessionId: String
    var cwd: String?
    var toolName: String?
    var toolInput: JSONValue?
    var permissionMode: String?
    var transcriptPath: String?
    var promptId: String?
    /// What Claude Code itself offers as a broader grant. "Allow and stop asking"
    /// is built from these rather than from a rule we invent.
    var permissionSuggestions: JSONValue?
    /// The hook process holding this request open. A dead pid is a dead request —
    /// without it, a SIGKILLed hook leaves a row nothing can ever clear.
    var pid: Int?
    var demo: Bool?

    var id: String { req }
}

struct SessionRecord: Codable, Sendable, Identifiable {
    var sessionId: String
    var state: InboxState
    var ts: Double
    var event: String?
    var cwd: String?
    var permissionMode: String?
    var transcriptPath: String?
    var endReason: String?
    var lastPrompt: String?
    var lastMessage: String?
    /// The tracker issue the session is working on, e.g. "SKY-5463". The bridge
    /// keeps it from the prompt that named it; a follow-up rarely names it again.
    var issue: String?
    /// `permission_prompt`, from the Notification that blocked it.
    var notificationType: String?
    var demo: Bool?

    // Filled in from the live registry and the transcript, not from the file.
    var name: String?
    var pid: Int?
    var waitingFor: String?
    var configDir: String?
    var phase: String?
    /// A short generated name, for a session that named no issue. See `Labels`.
    var label: String?
    /// The tool call a blocked session is stopped on, in the model's own words.
    var asking: String?
    /// Whether the turn ended by asking the person for something. See `Asks`.
    var needsYou = false
    /// What it asks for, or — when it asks nothing — what landed. One line.
    var line: String?
    /// Answers the person is likely to give. A tap drafts one; it never sends.
    var replies: [String] = []
    /// An answer nobody has opened yet — the blue dot Mail puts on a message.
    var unread = false
    /// Everything the filter matches against, built once per read. Building it
    /// per keystroke ran a dozen regular expressions per row, eight times over.
    var search = ""
    var title: String?
    var saying: String?
    var activity: [String] = []

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId, state, ts, event, cwd, permissionMode, transcriptPath
        // `phase` is written by the bridge when a session declares a step, so it
        // has to be decoded — leaving it out silently dropped every declared step
        // and put "working" back in rows that had something better to say.
        // `waitingFor` now comes from the hooks too, not only the live registry:
        // Notification carries what the session wants in Claude Code own words.
        case endReason, lastPrompt, lastMessage, demo, phase, waitingFor, issue, notificationType
        // Never written by the bridge; a demo row carries them so the panel can be
        // judged, and photographed, without a model in the loop.
        case label, needsYou, line, replies
    }

    /// Written by hand, and it has to stay that way.
    ///
    /// The synthesized decoder ignores a property's default value: a non-optional
    /// with a default still makes the key *required*, and one missing key throws
    /// out the whole record. `readJSONDir` swallows that with `try?`, so adding
    /// `needsYou` to the keys silently dropped every record the bridge had ever
    /// written — and the panel looked fine, because rows were being rebuilt from
    /// the live registry and the transcript. Only the demo rows, which carry every
    /// field, still decoded.
    ///
    /// So: `decodeIfPresent` for everything. A record is written by a shell script
    /// from a payload we do not control, and by an older bridge than this build —
    /// a missing field must degrade a row, never drop it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        state = try c.decodeIfPresent(InboxState.self, forKey: .state) ?? .working
        ts = try c.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        event = try c.decodeIfPresent(String.self, forKey: .event)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        endReason = try c.decodeIfPresent(String.self, forKey: .endReason)
        lastPrompt = try c.decodeIfPresent(String.self, forKey: .lastPrompt)
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        demo = try c.decodeIfPresent(Bool.self, forKey: .demo)
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        needsYou = try c.decodeIfPresent(Bool.self, forKey: .needsYou) ?? false
        line = try c.decodeIfPresent(String.self, forKey: .line)
        replies = try c.decodeIfPresent([String].self, forKey: .replies) ?? []
    }

    init(sessionId: String, state: InboxState, ts: Double) {
        self.sessionId = sessionId
        self.state = state
        self.ts = ts
    }

}

struct UsageRecord: Codable, Sendable, Identifiable {
    struct Window: Codable, Sendable {
        var usedPercentage: Double?
        var resetsAt: Double?
    }
    struct Limits: Codable, Sendable {
        var fiveHour: Window?
        var sevenDay: Window?
        var spendLimit: Window?
    }
    struct Context: Codable, Sendable {
        /// Null until the first API response of a session — not zero.
        var usedPercentage: Double?
        var contextWindowSize: Double?
    }
    struct Cost: Codable, Sendable {
        var totalCostUsd: Double?
    }

    var ts: Double
    var configDir: String
    var model: String?
    var rateLimits: Limits?
    var context: Context?
    var cost: Cost?

    var id: String { configDir }

    /// The highest of the two windows: what a threshold should watch.
    var peak: Double {
        max(rateLimits?.fiveHour?.usedPercentage ?? 0, rateLimits?.sevenDay?.usedPercentage ?? 0)
    }
}

/// Claude Code's own registry, `<config>/sessions/<pid>.json`. camelCase here,
/// snake_case in ours — two writers, two conventions, one reader.
struct LiveSession: Codable, Sendable {
    var pid: Int?
    var sessionId: String?
    var cwd: String?
    var name: String?
    var kind: String?
    var status: String?
    /// What a `waiting` session is waiting for, e.g. "input needed".
    var waitingFor: String?
    /// Epoch milliseconds. Zone-free, unlike `procStart`.
    var startedAt: Double?
    var statusUpdatedAt: Double?
}

/// A row is either a decision to make or a session to watch.
enum Row: Identifiable, Sendable {
    case pending(PendingItem)
    case session(SessionRecord)

    var id: String {
        switch self {
        case .pending(let p): "pending:" + p.req
        case .session(let s): "session:" + s.sessionId
        }
    }

    var state: InboxState {
        switch self {
        case .pending(let p): p.state
        case .session(let s): s.state
        }
    }

    var ts: Double {
        switch self {
        case .pending(let p): p.ts
        case .session(let s): s.ts
        }
    }

    var cwd: String? {
        switch self {
        case .pending(let p): p.cwd
        case .session(let s): s.cwd
        }
    }

    var transcriptPath: String? {
        switch self {
        case .pending(let p): p.transcriptPath
        case .session(let s): s.transcriptPath
        }
    }

    var sessionId: String {
        switch self {
        case .pending(let p): p.sessionId
        case .session(let s): s.sessionId
        }
    }
}

/// Just enough JSON to carry `tool_input` through without knowing its shape.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var count: Int {
        if case .array(let a) = self { return a.count }
        return 0
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
