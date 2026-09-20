import Foundation

/// Starting a session without opening a terminal.
///
/// This is the half of the product that closes the loop. A session started in a
/// terminal can be watched and unblocked from here, but a note written to it
/// arrives as a message from a peer and gets parked. A session started here runs
/// with an account chosen here, in a directory chosen here, and can be picked up
/// in a terminal later with `claude --resume` — nothing is lost by starting it
/// from a panel.
enum Launcher {
    enum Failure: Error, LocalizedError {
        case noCLI
        case noDirectory
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noCLI: "The `claude` command is not on PATH."
            case .noDirectory: "Pick a folder to start in."
            case .failed(let why): why
            }
        }
    }

    /// Folders worth offering, newest first: the ones sessions have actually run
    /// in. A list of every directory on the machine helps nobody.
    static func recentDirectories(from rows: [Row], limit: Int = 8) -> [String] {
        var seen: [String] = []
        for row in rows {
            guard let cwd = row.cwd, !cwd.isEmpty else { continue }
            // A temp directory is where a probe ran, not where work happens.
            if cwd.hasPrefix("/private/var/folders") || cwd.hasPrefix("/tmp") { continue }
            if !seen.contains(cwd) { seen.append(cwd) }
            if seen.count >= limit { break }
        }
        return seen
    }

    /// Launches in the background and returns the short id `claude` prints —
    /// the one `claude attach`, `logs` and `stop` take.
    @discardableResult
    static func start(prompt: String, in directory: String, configDir: String?) throws -> String {
        guard let executable = Accounts.executable else { throw Failure.noCLI }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw Failure.noDirectory }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--bg", prompt]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        var environment = ProcessInfo.processInfo.environment
        // The account is a per-process environment variable, which is the whole
        // reason accounts can be config directories: nothing global changes and
        // the sessions already running keep the account they started with.
        //
        // The default account is the exception and has to be left unnamed. Its
        // token lives in the Keychain, and setting CLAUDE_CONFIG_DIR — even to
        // its own path — sends Claude Code looking for credentials in the
        // directory instead, where there are none.
        let home = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        if let configDir, !configDir.isEmpty, configDir != home {
            environment["CLAUDE_CONFIG_DIR"] = configDir
        } else {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw Failure.failed(error.localizedDescription) }
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()

        let output = String(decoding: data ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure.failed("`claude --bg` exited \(process.terminationStatus).")
        }
        // "backgrounded · 5ef6d487"
        let id = output.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        return id
    }
}
