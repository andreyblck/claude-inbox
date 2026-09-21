import Darwin
import Foundation

/// Sending a message into a session that is already running.
///
/// Claude Code gives every session a Unix socket and publishes a token beside it,
/// and documents the handshake itself:
///
///     {"type":"auth","token":"…"}
///     {"type":"user","message":{"role":"user","content":"…"}}
///
/// One thing to be honest about, in the UI and here: the session renders this as
/// *"Another Claude session sent a message"*, with a preamble telling it to treat
/// the sender as a teammate rather than as you. There is no mode that says
/// otherwise, and there should not be — an outside process must not be able to
/// impersonate the person at the keyboard. So this is a nudge into a session, not
/// a substitute for typing in it.
enum Peer {
    enum Failure: Error, LocalizedError {
        case noSocket
        case noToken
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .noSocket: "That session is not listening — it may have ended."
            case .noToken: "No key published for that session."
            case .refused(let why): why
            }
        }
    }

    /// `/tmp/cc-socks/<pid>.sock`, the only place Claude Code puts these on macOS.
    private static func socketPath(pid: Int) -> String? {
        for dir in ["/tmp/cc-socks", "/private/tmp/cc-socks"] {
            let path = "\(dir)/\(pid).sock"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// `<config>/sessions/<pid>.<64 hex>.key`, holding `{"peerToken": "…"}`.
    private static func token(pid: Int) -> String? {
        for configDir in Inbox.configDirs() {
            let dir = (configDir as NSString).appendingPathComponent("sessions")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasPrefix("\(pid).") && name.hasSuffix(".key") {
                let file = (dir as NSString).appendingPathComponent(name)
                guard let data = FileManager.default.contents(atPath: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["peerToken"] as? String
                else { continue }
                return token
            }
        }
        return nil
    }

    static func canReach(pid: Int?) -> Bool {
        guard let pid else { return false }
        return socketPath(pid: pid) != nil && token(pid: pid) != nil
    }

    /// Who sent this, and through what.
    ///
    /// It is attribution, not authority — and cannot be authority: anything
    /// running as this user could write the same line, so a session must not
    /// treat it as approval, and Claude Code's own preamble says exactly that.
    /// What it does buy is the thing a session complained about out loud when it
    /// received four bare words in a row — "подписи нет, ответить некому". A note
    /// that says it is a person's typed words relayed from a panel is a different
    /// object from an unsigned imperative, and can be weighed as one.
    static func signed(_ text: String) -> String {
        let who = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let from = who.isEmpty ? "the person at this Mac" : who
        return "[Claude Inbox] Typed by \(from) in the Claude Inbox panel and relayed here.\n\n" + text
    }

    static func send(_ text: String, toPID pid: Int) throws {
        guard let path = socketPath(pid: pid) else { throw Failure.noSocket }
        guard let token = token(pid: pid) else { throw Failure.noToken }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.refused("Could not open a socket.") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else { throw Failure.refused("Socket path is too long.") }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.refused("That session refused the connection.") }

        // The auth line is required and must come first, on its own line.
        let auth: [String: Any] = ["type": "auth", "token": token]
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": signed(text)],
        ]
        for payload in [auth, message] {
            guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
                throw Failure.refused("Could not encode the message.")
            }
            data.append(0x0A)
            try data.withUnsafeBytes { buffer in
                var sent = 0
                while sent < buffer.count {
                    let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                    guard n > 0 else { throw Failure.refused("The session closed the connection.") }
                    sent += n
                }
            }
        }
        // The socket is one-way; a delivered message produces no reply here.
        shutdown(fd, SHUT_WR)
    }
}
