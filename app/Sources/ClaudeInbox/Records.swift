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
    var demo: Bool?

    // Filled in from the live registry and the transcript, not from the file.
    var name: String?
    var pid: Int?
    var waitingFor: String?
    var configDir: String?
    var phase: String?
    var title: String?
    var saying: String?
    var activity: [String] = []

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId, state, ts, event, cwd, permissionMode, transcriptPath
        // `phase` is written by the bridge when a session declares a step, so it
        // has to be decoded — leaving it out silently dropped every declared step
        // and put "working" back in rows that had something better to say.
        case endReason, lastPrompt, lastMessage, demo, phase
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
enum JSONValue: Codable, Sendable {
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
}
