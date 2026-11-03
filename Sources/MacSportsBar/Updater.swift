import AppKit
import Foundation

/// What this copy of the app is. `scripts/build-app.sh` records the commit it built from in
/// `Info.plist`; that commit, not the version string, is what the update check compares.
struct BuildInfo: Equatable {
    var version: String
    var commit: String?
    /// The `.app` to replace on update; nil when not running from one (`swift run`).
    var appBundle: URL?

    init(infoDictionary: [String: Any], bundleURL: URL) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "dev"
        commit = (infoDictionary["MSBGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        appBundle = bundleURL.pathExtension == "app" ? bundleURL : nil
    }

    static var current: BuildInfo {
        BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:], bundleURL: Bundle.main.bundleURL)
    }

    /// "0.1.0 (c17b582)", or just the version when the commit isn't known.
    var label: String {
        commit.map { "\(version) (\($0.prefix(7)))" } ?? version
    }
}

/// The answer to "is there anything newer on `main`?".
enum UpdateCheck: Equatable {
    case upToDate
    /// `main` has commits this build lacks. `newCommits` is how many, and `subjects` the newest
    /// few commit titles; nil and empty when this build can't be compared to `main`.
    case available(newCommits: Int?, subjects: [String])

    static let subjectLimit = 5

    /// Read GitHub's compare response for `<build commit>...main`. Pure — the seam the tests use.
    /// A 404 means GitHub doesn't know the commit (built from unpushed work), so the build can't
    /// be compared but `main` is still installable. A local build ahead of `main` is up to date;
    /// one that has diverged from it still lacks `main`'s commits, so an update is on offer.
    static func from(statusCode: Int, data: Data) throws -> UpdateCheck {
        switch statusCode {
        case 200..<300: break
        case 404:       return .available(newCommits: nil, subjects: [])
        case 403, 429:  throw UpdateError.rateLimited
        default:        throw UpdateError.badStatus(statusCode)
        }
        let compare = try JSONDecoder().decode(Compare.self, from: data)
        guard compare.aheadBy > 0 else { return .upToDate }
        // The API lists commits oldest first; the newest are the ones worth showing.
        let subjects = compare.commits.reversed().prefix(subjectLimit).map {
            String($0.commit.message.prefix { !$0.isNewline })
        }
        return .available(newCommits: compare.aheadBy, subjects: subjects)
    }

    private struct Compare: Decodable {
        let aheadBy: Int
        let commits: [Entry]

        struct Entry: Decodable {
            let commit: Commit
        }

        struct Commit: Decodable {
            let message: String
        }

        enum CodingKeys: String, CodingKey {
            case aheadBy = "ahead_by"
            case commits
        }
    }
}

enum UpdateError: Error, Equatable, CustomStringConvertible {
    case rateLimited
    case badStatus(Int)
    case noToolchain
    case notWritable(String)
    case downloadFailed
    case buildFailed
    case swapFailed(String)

    var description: String {
        switch self {
        case .rateLimited:
            return "GitHub's hourly limit for update checks was reached. Try again later."
        case .badStatus(let code):
            return "GitHub answered with an error (HTTP \(code)). Try again later."
        case .noToolchain:
            return "Updating builds from source, which needs Xcode or the Command Line Tools. Run `xcode-select --install`, then try again."
        case .notWritable(let folder):
            return "Can't replace the app because \(folder) isn't writable by your account. Nothing was changed."
        case .downloadFailed:
            return "Couldn't download the source from GitHub. Nothing was changed."
        case .buildFailed:
            return "The latest source didn't build. Your installed app wasn't changed."
        case .swapFailed(let reason):
            return "Couldn't replace the app (\(reason)). Your installed app wasn't changed."
        }
    }
}

/// Asks GitHub how this build compares to `main`. The repo is public, so no token is needed;
/// the unauthenticated limit of 60 requests an hour is plenty for a button.
struct UpdateClient {
    var baseURL = URL(string: "https://api.github.com/repos/Revelation-Hosting/MacSportsBar")!
    var timeout: TimeInterval = 15
    var session: URLSession = .shared

    func check(from commit: String) async throws -> UpdateCheck {
        var request = URLRequest(url: baseURL.appendingPathComponent("compare/\(commit)...main"))
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacSportsBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        return try UpdateCheck.from(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
}

enum UpdatePhase: Equatable {
    case downloading, building, installing
}

/// Fetches `main`, builds it with the repo's own `scripts/build-app.sh`, and swaps the result in
/// over the running app — the steps of a manual install. Everything that can fail runs before the
/// swap, so a failed update leaves the installed app as it was.
///
/// Each update starts from a fresh shallow clone. Release builds compile the whole module at once,
/// so a kept checkout would save little build time and could go stale across toolchain upgrades.
struct UpdateInstaller {
    var repository = URL(string: "https://github.com/Revelation-Hosting/MacSportsBar.git")!
    var branch = "main"
    /// Scratch space for the clone and its build; removed when the update ends.
    var workDirectory: URL
    var logFile: URL
    var downloadLimit: Double = 5 * 60
    var buildLimit: Double = 20 * 60

    private static let bundleName = "MacSportsBar.app"

    func install(over target: URL, progress: @escaping @Sendable (UpdatePhase) -> Void) async throws {
        let files = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard files.isWritableFile(atPath: folder.path) else {
            throw UpdateError.notWritable(folder.path)
        }
        guard Self.hasToolchain else { throw UpdateError.noToolchain }

        try? files.removeItem(at: workDirectory)
        try files.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workDirectory) }
        try files.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile)
        defer { try? log.close() }

        let source = workDirectory.appendingPathComponent("source")
        progress(.downloading)
        // A clone that stalls fails on the low-speed limit; the deadline is the backstop.
        guard await run(
            "/usr/bin/git",
            ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=60", "clone", "--depth", "1",
             "--branch", branch, repository.absoluteString, source.path],
            in: workDirectory, limit: downloadLimit, log: log
        ) else { throw UpdateError.downloadFailed }

        progress(.building)
        let built = source.appendingPathComponent(Self.bundleName)
        guard await run("/bin/bash", ["scripts/build-app.sh"], in: source, limit: buildLimit, log: log),
              files.isExecutableFile(atPath: built.appendingPathComponent("Contents/MacOS/MacSportsBar").path)
        else { throw UpdateError.buildFailed }

        progress(.installing)
        try Self.swap(built, over: target)
    }

    /// Replace `target` with a copy of `new`. The exchange is a single atomic rename, so the app
    /// is complete at every instant and an interrupted update can't leave it half-written. The
    /// running app is unaffected: its files stay open until it quits, and it relaunches into the
    /// new bundle.
    static func swap(_ new: URL, over target: URL) throws {
        let files = FileManager.default
        // A sibling, because the exchange only works within a volume. No `.app` extension, so
        // Launch Services never mistakes it for another copy of the app.
        let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).incoming")
        try? files.removeItem(at: staged)
        defer { try? files.removeItem(at: staged) }  // the old app, once they've changed places
        do {
            try files.copyItem(at: new, to: staged)
        } catch {
            throw UpdateError.swapFailed(error.localizedDescription)
        }
        guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.swapFailed(String(cString: strerror(errno)))
        }
    }

    /// Whether a developer directory is selected. Checked first because on a Mac without one,
    /// `/usr/bin/git` is a stub that pops the system's install dialog instead of running.
    static var hasToolchain: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Run a step to completion with its output in the log, reporting whether it succeeded. A
    /// step that outlives `limit` is terminated and counts as failed.
    private func run(
        _ tool: String, _ arguments: [String], in directory: URL, limit: Double, log: FileHandle
    ) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = log
        process.standardError = log
        // An app launched from Finder doesn't get a shell's PATH, and these tools don't need one:
        // everything build-app.sh calls lives in the system directories. Git must never stop to
        // ask for credentials, since nobody could answer.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        do {
            try await withDeadline(seconds: limit) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? log.write(contentsOf: Data("\(tool) failed: \(error)\n".utf8))
            return false
        }
        return process.terminationStatus == 0
    }
}

/// Drives the Settings window's Updates section: check, then build, swap and relaunch. It outlives
/// the window, so closing Settings mid-build doesn't interrupt anything.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(newCommits: Int?, subjects: [String])
        case installing(UpdatePhase)
        case failed(String, hasLog: Bool)
    }

    @Published private(set) var state: State = .idle

    let build = BuildInfo.current
    let logFile: URL

    private let client = UpdateClient()
    private let installer: UpdateInstaller

    private init() {
        let files = FileManager.default
        logFile = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacSportsBar/update.log")
        installer = UpdateInstaller(
            workDirectory: files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.revelationhosting.macsportsbar/update"),
            logFile: logFile
        )
    }

    func check() {
        state = .checking
        Task {
            do {
                state = try await compareToMain()
            } catch let error as UpdateError {
                state = .failed(error.description, hasLog: false)
            } catch {
                state = .failed("Couldn't reach GitHub: \(error)", hasLog: false)
            }
        }
    }

    /// Bounded like every league fetch: a request stranded by sleep must not spin forever.
    private func compareToMain() async throws -> State {
        guard let commit = build.commit else { return .available(newCommits: nil, subjects: []) }
        let client = client
        let result = try await withDeadline(seconds: 30) { try await client.check(from: commit) }
        switch result {
        case .upToDate:
            return .upToDate
        case .available(let newCommits, let subjects):
            return .available(newCommits: newCommits, subjects: subjects)
        }
    }

    func install() {
        guard let target = build.appBundle else { return }
        state = .installing(.downloading)
        let installer = installer
        Task {
            do {
                try await installer.install(over: target) { phase in
                    Task { @MainActor in self.state = .installing(phase) }
                }
                Self.relaunch(target)
            } catch let error as UpdateError {
                state = .failed(error.description, hasLog: error == .downloadFailed || error == .buildFailed)
            } catch {
                state = .failed("The update failed: \(error)", hasLog: false)
            }
        }
    }

    /// Quit and reopen from `app`. A small shell outlives this process and waits for it to exit,
    /// because `open` would otherwise just activate the copy that's still quitting.
    private static func relaunch(_ app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#,
            "sh", String(ProcessInfo.processInfo.processIdentifier), app.path,
        ]
        try? waiter.run()
        NSApp.terminate(nil)
    }
}
