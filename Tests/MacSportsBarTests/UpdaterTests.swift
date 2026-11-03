import XCTest
@testable import MacSportsBar

/// Tests for the in-app updater: reading GitHub's compare response, what the app knows about
/// itself, and the fetch → build → swap pipeline. The pipeline runs for real against a local git
/// repo whose `build-app.sh` is a stand-in, so it stays hermetic and quick. What matters most is
/// that every failure leaves the installed app untouched.
final class UpdaterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Compare response

    private func compare(aheadBy: Int, behindBy: Int = 0, messages: [String] = []) -> Data {
        let commits = messages.map { ["commit": ["message": $0]] }
        let body: [String: Any] = ["ahead_by": aheadBy, "behind_by": behindBy, "commits": commits]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testIdenticalBuildIsUpToDate() throws {
        XCTAssertEqual(try UpdateCheck.from(statusCode: 200, data: compare(aheadBy: 0)), .upToDate)
    }

    func testBuildAheadOfMainIsUpToDate() throws {
        XCTAssertEqual(try UpdateCheck.from(statusCode: 200, data: compare(aheadBy: 0, behindBy: 3)), .upToDate)
    }

    func testNewCommitsAreListedNewestFirstByTitleOnly() throws {
        let data = compare(aheadBy: 2, messages: ["Older\n\nBody text", "Newer (#9)"])
        XCTAssertEqual(try UpdateCheck.from(statusCode: 200, data: data),
                       .available(newCommits: 2, subjects: ["Newer (#9)", "Older"]))
    }

    func testDivergedBuildStillOffersMainsCommits() throws {
        let data = compare(aheadBy: 1, behindBy: 4, messages: ["On main"])
        XCTAssertEqual(try UpdateCheck.from(statusCode: 200, data: data),
                       .available(newCommits: 1, subjects: ["On main"]))
    }

    func testLongHistoryKeepsTheFullCountButOnlyTheNewestTitles() throws {
        let messages = (1...8).map { "Commit \($0)" }
        let data = compare(aheadBy: 8, messages: messages)
        XCTAssertEqual(try UpdateCheck.from(statusCode: 200, data: data),
                       .available(newCommits: 8, subjects: ["Commit 8", "Commit 7", "Commit 6", "Commit 5", "Commit 4"]))
    }

    func testCommitUnknownToGitHubCanStillUpdate() throws {
        XCTAssertEqual(try UpdateCheck.from(statusCode: 404, data: Data()),
                       .available(newCommits: nil, subjects: []))
    }

    func testRateLimitAndServerErrorsAreReported() {
        XCTAssertThrowsError(try UpdateCheck.from(statusCode: 403, data: Data())) {
            XCTAssertEqual($0 as? UpdateError, .rateLimited)
        }
        XCTAssertThrowsError(try UpdateCheck.from(statusCode: 429, data: Data())) {
            XCTAssertEqual($0 as? UpdateError, .rateLimited)
        }
        XCTAssertThrowsError(try UpdateCheck.from(statusCode: 502, data: Data())) {
            XCTAssertEqual($0 as? UpdateError, .badStatus(502))
        }
    }

    func testMalformedBodyThrows() {
        XCTAssertThrowsError(try UpdateCheck.from(statusCode: 200, data: Data("nope".utf8)))
    }

    // MARK: - BuildInfo

    func testBuildInfoReadsTheRecordedCommit() {
        let info = BuildInfo(
            infoDictionary: ["CFBundleShortVersionString": "0.1.0", "MSBGitCommit": "c17b58243efdba40"],
            bundleURL: URL(fileURLWithPath: "/Applications/MacSportsBar.app"))
        XCTAssertEqual(info.label, "0.1.0 (c17b582)")
        XCTAssertEqual(info.appBundle?.path, "/Applications/MacSportsBar.app")
    }

    func testBlankCommitReadsAsUnknown() {
        let info = BuildInfo(
            infoDictionary: ["CFBundleShortVersionString": "0.1.0", "MSBGitCommit": ""],
            bundleURL: URL(fileURLWithPath: "/Applications/MacSportsBar.app"))
        XCTAssertNil(info.commit)
        XCTAssertEqual(info.label, "0.1.0")
    }

    func testSwiftRunHasNoBundleToReplace() {
        let info = BuildInfo(infoDictionary: [:], bundleURL: URL(fileURLWithPath: "/repo/.build/debug"))
        XCTAssertNil(info.appBundle)
        XCTAssertEqual(info.label, "dev")
    }

    // MARK: - Swap

    /// A minimal stand-in for an app bundle whose marker file says which build it is.
    private func makeApp(at url: URL, marker: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try marker.write(to: macOS.appendingPathComponent("MacSportsBar"), atomically: true, encoding: .utf8)
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/MacOS/MacSportsBar"), encoding: .utf8)
    }

    /// Everything in `folder`, hidden files included, so a leftover staging copy can't hide.
    private func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testSwapReplacesTheAppAndLeavesNothingBehind() throws {
        let installed = root.appendingPathComponent("Installed/MacSportsBar.app")
        let built = root.appendingPathComponent("Built/MacSportsBar.app")
        try makeApp(at: installed, marker: "old")
        try makeApp(at: built, marker: "new")
        // A stale staging copy from an interrupted update must not get in the way.
        try makeApp(at: root.appendingPathComponent("Installed/.MacSportsBar.app.incoming"), marker: "stale")

        try UpdateInstaller.swap(built, over: installed)

        XCTAssertEqual(try marker(of: installed), "new")
        XCTAssertEqual(try contents(of: installed.deletingLastPathComponent()), ["MacSportsBar.app"])
    }

    func testSwapFailureLeavesNoStagingCopy() throws {
        let folder = root.appendingPathComponent("Installed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let built = root.appendingPathComponent("Built/MacSportsBar.app")
        try makeApp(at: built, marker: "new")

        // Nothing at the target to exchange with.
        XCTAssertThrowsError(try UpdateInstaller.swap(built, over: folder.appendingPathComponent("MacSportsBar.app")))
        XCTAssertEqual(try contents(of: folder), [])
    }

    // MARK: - Install pipeline

    @discardableResult
    private func git(_ arguments: String..., in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
        return process.terminationStatus
    }

    /// A repo on `main` whose build script is `buildScript`, standing in for `scripts/build-app.sh`.
    private func makeRepo(buildScript: String) throws -> URL {
        let repo = root.appendingPathComponent("repo")
        let scripts = repo.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try buildScript.write(to: scripts.appendingPathComponent("build-app.sh"), atomically: true, encoding: .utf8)
        try git("init", "-b", "main", in: repo)
        try git("add", ".", in: repo)
        try git("commit", "-m", "Initial", in: repo)
        return repo
    }

    private func makeInstaller(repository: URL) -> UpdateInstaller {
        UpdateInstaller(
            repository: repository,
            workDirectory: root.appendingPathComponent("work"),
            logFile: root.appendingPathComponent("logs/update.log"))
    }

    private let goodBuild = """
        set -e
        mkdir -p MacSportsBar.app/Contents/MacOS
        printf new > MacSportsBar.app/Contents/MacOS/MacSportsBar
        chmod +x MacSportsBar.app/Contents/MacOS/MacSportsBar
        echo built on PATH=$PATH
        """

    func testInstallBuildsMainAndReplacesTheApp() async throws {
        let repo = try makeRepo(buildScript: goodBuild)
        let installed = root.appendingPathComponent("Installed/MacSportsBar.app")
        try makeApp(at: installed, marker: "old")
        let phases = PhaseRecorder()
        let installer = makeInstaller(repository: repo)

        try await installer.install(over: installed) { phases.record($0) }

        XCTAssertEqual(try marker(of: installed), "new")
        XCTAssertEqual(phases.seen, [.downloading, .building, .installing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.workDirectory.path), "scratch space is removed")
        let log = try String(contentsOf: installer.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("built on PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "the build's output is logged: \(log)")
    }

    func testFailedBuildLeavesTheAppAndLogsWhy() async throws {
        let repo = try makeRepo(buildScript: "echo compile error here >&2; exit 1")
        let installed = root.appendingPathComponent("Installed/MacSportsBar.app")
        try makeApp(at: installed, marker: "old")
        let installer = makeInstaller(repository: repo)

        await assertInstallFails(installer, over: installed, with: .buildFailed)

        XCTAssertEqual(try marker(of: installed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.workDirectory.path))
        XCTAssertTrue(try String(contentsOf: installer.logFile, encoding: .utf8).contains("compile error here"))
    }

    func testBuildThatProducesNoAppCountsAsFailed() async throws {
        let repo = try makeRepo(buildScript: "exit 0")
        let installed = root.appendingPathComponent("Installed/MacSportsBar.app")
        try makeApp(at: installed, marker: "old")

        await assertInstallFails(makeInstaller(repository: repo), over: installed, with: .buildFailed)
        XCTAssertEqual(try marker(of: installed), "old")
    }

    func testBuildThatOutlivesItsLimitCountsAsFailed() async throws {
        let repo = try makeRepo(buildScript: "exec sleep 30")
        let installed = root.appendingPathComponent("Installed/MacSportsBar.app")
        try makeApp(at: installed, marker: "old")
        var installer = makeInstaller(repository: repo)
        installer.buildLimit = 0.5

        let started = ContinuousClock.now
        await assertInstallFails(installer, over: installed, with: .buildFailed)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        XCTAssertEqual(try marker(of: installed), "old")
    }

    func testUnreachableRepositoryIsADownloadFailure() async throws {
        let installed = root.appendingPathComponent("Installed/MacSportsBar.app")
        try makeApp(at: installed, marker: "old")
        let missing = root.appendingPathComponent("no-such-repo")

        await assertInstallFails(makeInstaller(repository: missing), over: installed, with: .downloadFailed)
        XCTAssertEqual(try marker(of: installed), "old")
    }

    func testUnwritableFolderFailsBeforeAnyWork() async throws {
        let folder = root.appendingPathComponent("Installed")
        let installed = folder.appendingPathComponent("MacSportsBar.app")
        try makeApp(at: installed, marker: "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let installer = makeInstaller(repository: root.appendingPathComponent("unused"))

        await assertInstallFails(installer, over: installed, with: .notWritable(folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.workDirectory.path))
    }

    private func assertInstallFails(
        _ installer: UpdateInstaller, over target: URL, with expected: UpdateError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await installer.install(over: target) { _ in }
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UpdateError, expected, file: file, line: line)
        }
    }

    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [UpdatePhase] = []
        var seen: [UpdatePhase] { lock.lock(); defer { lock.unlock() }; return phases }
        func record(_ phase: UpdatePhase) { lock.lock(); phases.append(phase); lock.unlock() }
    }
}
