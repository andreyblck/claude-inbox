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
    enum Failure: Error, LocalizedError {
        case noCLI
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noCLI: "The `claude` command is not on PATH."
            case .failed(let why): why
            }
        }
    }

    private static var executable: String? {
        for path in [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

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
            let project = Format.projectName(cwd: s.cwd, fallback: s.sessionId, name: s.name)
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
        guard let executable else { throw Failure.noCLI }
        let brief = Self.brief(for: rows)
        guard !brief.isEmpty else { return "Nothing is running." }

        let prompt = """
            Ниже — состояние параллельных сессий Claude Code одного человека, \
            который только что вернулся к машине. Для каждой: состояние, проект и \
            то, что она сказала последним.

            Напиши короткую сводку — что произошло и что требует его внимания. \
            Правила: пиши на языке, на котором написаны сами сессии. Не пересказывай \
            всё подряд — назови то, что изменилось и то, что застряло. Сначала то, \
            что ждёт решения, потом что доделано, потом что идёт. Никаких \
            вступлений и никаких предложений помощи. Максимум 8 строк.

            \(brief)
            """

        // The digest session would otherwise report itself into the inbox it is
        // summarising. Pointing its hooks at a throwaway directory keeps it out
        // of its own reading.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-inbox-digest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-p", prompt,
            "--model", "claude-haiku-4-5-20251001",
            "--max-turns", "1",
            "--permission-prompts", "none",
            "--output-format", "text",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_INBOX_DIR"] = scratch.path
        process.environment = environment

        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        // Without this the child inherits a stdin that never closes and can sit
        // waiting on it forever.
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = scratch

        do { try process.run() } catch { throw Failure.failed(error.localizedDescription) }
        let data = try? out.fileHandleForReading.readToEnd()
        process.waitUntilExit()

        let text = String(decoding: data ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            throw Failure.failed("The digest did not come back. Quota or auth, most likely.")
        }
        return text
    }
}
