import Foundation

/// The hooks, shipped inside the app and installed from it.
///
/// A person who downloaded a disk image has no clone to run `install.sh` from,
/// and an app that opens to "run a script from the repository" is an app they
/// close. So the bridge travels in `Contents/Resources/bridge`, and the same
/// `install.sh` that a clone uses runs from there: the hooks it writes into
/// `settings.json` point into the app bundle, and moving the app is what
/// reinstalling is for.
enum Bridge {
    /// `install.sh` inside this bundle, or nil for a bare `swift build` binary,
    /// which has no resources and whose person has the clone anyway.
    static var bundledInstaller: String? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("bridge/install.sh").path,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    enum Failure: Error, LocalizedError {
        case notBundled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled: "This build carries no bridge. Run bridge/install.sh from the clone."
            case .failed(let why): why
            }
        }
    }

    /// Blocking, and never called from the main actor: it runs a script that
    /// rewrites `settings.json`, with a backup first — the script's job, not ours.
    static func run(uninstall: Bool) throws -> String {
        guard let installer = bundledInstaller else { throw Failure.notBundled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installer] + (uninstall ? ["--uninstall"] : [])
        var environment = ProcessInfo.processInfo.environment
        // The hooks need to find the same jq and python the script does; an app
        // launched from Finder has a PATH that knows neither.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.failed(error.localizedDescription) }
        let data = try? out.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        let text = String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure.failed(text.isEmpty ? "install.sh exited with \(process.terminationStatus)." : text)
        }
        return text
    }
}
