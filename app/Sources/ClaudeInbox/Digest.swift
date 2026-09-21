import Foundation

/// One paragraph for a dozen sessions.
///
/// The panel answers "what is each one doing" a row at a time. The question a
/// person comes back to the machine with is the other one — *what happened while
/// I was away* — and that one is not a row, it is a reading across all of them.
///
/// It runs the `claude` already on the machine rather than holding an API key of
/// its own: the account, the auth and the quota are the ones already set up, and
/// there is nothing extra to configure or to leak.
enum Digest {
    /// What the model is given. Deliberately only what is already on screen:
    /// state, project, and what each session last said.
    static func brief(for rows: [Row]) -> String {
        var lines: [String] = []
        for row in rows {
            guard case .session(let s) = row else {
                if case .pending(let p) = row {
                    let project = Format.projectName(cwd: p.cwd, fallback: p.sessionId, name: nil)
                    lines.append("- [BLOCKED] \(project): waiting for permission to \(Format.askPhrase(p, max: 100))")
                }
                continue
            }
            let project = Format.label(s)
            let said = (s.lastMessage ?? s.saying).map { Format.plainText($0).prefix(700) } ?? ""
            lines.append("- [\(s.state.label.uppercased())] \(project): \(said)")
        }
        return lines.joined(separator: "\n")
    }

    /// Blocking on purpose, and never called from the main actor.
    ///
    /// It was `async` first, which reads as "safe to await anywhere" and is not:
    /// the work inside is a subprocess and a blocking read, so an await on the
    /// main actor freezes the panel for as long as a model takes to answer. A
    /// synchronous signature says what it is and forces the caller to say where
    /// it runs.
    static func make(for rows: [Row]) throws -> String {
        let brief = Self.brief(for: rows)
        guard !brief.isEmpty else { return "Nothing is running." }

        let prompt = """
            Below is the state of one person's parallel Claude Code sessions. They \
            have just come back to the machine. For each: its state, which one it is, \
            and the last thing it said.

            Write a short digest — what happened and what needs their attention. \
            Write in the language the sessions themselves are written in. Do not \
            retell everything: name what changed and what is stuck. First what is \
            waiting on a decision, then what got done, then what is in progress. No \
            preamble and no offers of help. Eight lines at most.

            \(brief)
            """

        return try ClaudeCLI.ask(prompt)
    }
}
