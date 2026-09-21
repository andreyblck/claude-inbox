import Foundation

/// One question to the `claude` already on the machine, and its answer.
///
/// The account, the auth and the quota are the ones already set up, so there is
/// no key to hold and nothing to configure. `--bare` would start in a second
/// instead of ten, and cannot be used: it reads neither OAuth nor the keychain.
enum ClaudeCLI {
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

    /// The directory every question is asked from. A `claude -p` run registers
    /// like any session, and this name is how its row is told from somebody's
    /// work — without it the panel lists its own plumbing for ten seconds.
    static let scratchPrefix = "claude-inbox-ask-"

    /// Where `claude` is, asked once. The usual places first; then the person's
    /// own login shell, because an npm install under nvm, volta or a custom prefix
    /// is on their PATH and nowhere an app launched from Finder would look.
    private static let executable: String? = {
        let usual = [
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let hit = usual.first(where: FileManager.default.isExecutableFile(atPath:)) { return hit }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lic", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = try? out.fileHandleForReading.readToEnd()
        shell.waitUntilExit()
        let path = String(decoding: data ?? Data(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }()

    /// Blocking on purpose, and never called from the main actor: the work is a
    /// subprocess and a blocking read, and an `async` signature would read as
    /// "safe to await anywhere" when it freezes the panel for ten seconds.
    static func ask(_ prompt: String) throws -> String {
        guard let executable else { throw Failure.noCLI }

        // The session would otherwise report itself into the inbox it is reading.
        // Pointing its hooks at a throwaway directory keeps it out.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchPrefix + UUID().uuidString)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-p", prompt,
            "--model", "claude-haiku-4-5-20251001",
            "--max-turns", "1",
            // A prompt with a link in it sends the model for a tool, and one turn
            // is then spent asking for it: "Reached max turns (1)", exit 1, no
            // text. With nothing to reach for, it answers.
            "--tools", "",
            "--strict-mcp-config",
            // The person's own settings come along otherwise, and one of them is
            // the language to answer in: with `"language": "Russian"` a line about
            // an English session came back in Russian every other time. Their
            // plugins and hooks have no business in a one-line question either.
            "--setting-sources", "local",
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
            throw Failure.failed("`claude` did not answer (exit \(process.terminationStatus)).")
        }
        return text
    }
}
