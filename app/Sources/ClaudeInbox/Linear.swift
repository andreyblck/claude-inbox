import AppKit

/// The way from an issue key back to the issue.
///
/// A link names the workspace, a bare `SKY-4483` does not — so the workspace is
/// remembered from the first link seen, which for a team is the only one there is.
enum Linear {
    private static let key = "linearWorkspace"

    static func remember(from text: String?) {
        guard let text,
              let regex = try? NSRegularExpression(pattern: "linear\\.app/([A-Za-z0-9_-]+)/issue/", options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return }
        let workspace = String(text[range])
        if UserDefaults.standard.string(forKey: key) != workspace {
            UserDefaults.standard.set(workspace, forKey: key)
        }
    }

    static func url(for issue: String?) -> URL? {
        guard let issue, !issue.isEmpty, let workspace = UserDefaults.standard.string(forKey: key) else { return nil }
        return URL(string: "https://linear.app/\(workspace)/issue/\(issue)")
    }

    static func open(_ issue: String?) {
        if let url = url(for: issue) { NSWorkspace.shared.open(url) }
    }
}

/// Bringing forward the app a session is running in.
///
/// Which *tab* is the terminal's business, and most terminals — Warp among them —
/// offer no way to ask for one. The window is the most that can honestly be
/// promised, so that is what this does: walk up from the session to the first
/// process that is an app, and activate it.
enum Terminal {
    static func reveal(pid: Int?) {
        guard var current = pid.map(Int32.init) else { return }
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                app.activate(options: [.activateAllWindows])
                return
            }
            guard let parent = parentPID(of: current), parent > 1 else { return }
            current = parent
        }
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// Which answers have been opened. An answer is new again when the turn is.
enum Reads {
    private static let key = "readAnswers"

    static func isRead(_ sessionId: String, ts: Double) -> Bool {
        let seen = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return (seen[sessionId] ?? 0) >= ts
    }

    static func mark(_ sessionId: String, ts: Double) {
        var seen = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard (seen[sessionId] ?? 0) < ts else { return }
        seen[sessionId] = ts
        // One entry per session ever opened would grow for good.
        if seen.count > 400 {
            let keep = seen.sorted { $0.value > $1.value }.prefix(200)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(seen, forKey: key)
    }
}
