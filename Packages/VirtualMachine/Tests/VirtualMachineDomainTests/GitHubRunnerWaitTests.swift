import Foundation
import GitHubDomain
import LoggingDomain
import SSHDomain
@testable import VirtualMachineDomain
import XCTest

private enum RunnerError: Error { case removalFailed, lookupFailed }

private actor RunnerClient: GitHubClient {
    var statuses: [GitHubRunnerStatus?]
    let removalFails: Bool
    let hasJobs: Bool
    var lookupFailures: Int
    private(set) var removals = 0
    var queueConnection: Connection?

    init(statuses: [GitHubRunnerStatus?], removalFails: Bool = false, lookupFailures: Int = 0, hasJobs: Bool = true) {
        self.statuses = statuses
        self.removalFails = removalFails
        self.hasJobs = hasJobs
        self.lookupFailures = lookupFailures
    }
    func getRunner(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                   name: String) async throws -> GitHubRunnerStatus? {
        if lookupFailures > 0 {
            lookupFailures -= 1
            throw RunnerError.lookupFailed
        }
        return statuses.removeFirst()
    }
    func removeRunner(with token: GitHubAppAccessToken, target: GitHubRunnerTarget, id: Int) async throws {
        removals += 1
        if removalFails { throw RunnerError.removalFailed }
    }
    func getAppAccessToken(target: GitHubRunnerTarget) async throws -> GitHubAppAccessToken {
        if let connection = queueConnection {
            let commands = await connection.commands
            if commands.contains(where: { $0.hasPrefix("open -a Terminal") }) {
                throw RunnerError.lookupFailed
            }
        }
        return GitHubAppAccessToken("fixture-token")
    }
    func getQueuedJobCount(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                           labels: Set<String>) async throws -> Int {
        try await queueConnection?.executeCommand("# queue checked")
        return hasJobs && target == .organization("b") ? 1 : 0
    }
    func observeQueue(through connection: Connection) { queueConnection = connection }
    func getRunnerRegistrationToken(with token: GitHubAppAccessToken,
                                    target: GitHubRunnerTarget) async throws -> GitHubRunnerRegistrationToken {
        GitHubRunnerRegistrationToken("fixture-registration-token")
    }
    func getRunnerDownloadURL(with token: GitHubAppAccessToken,
                              target: GitHubRunnerTarget) async throws -> URL {
        URL(string: "https://example.com/runner.tar.gz")!
    }
}

private actor Connection: SSHConnection {
    private(set) var commands: [String] = []
    private var queueWaiter: CheckedContinuation<Void, Never>?
    func executeCommand(_ command: String) async throws {
        commands.append(command)
        if command == "# queue checked" {
            queueWaiter?.resume()
            queueWaiter = nil
        }
    }
    func waitForQueueCheck() async {
        if commands.contains("# queue checked") { return }
        await withCheckedContinuation { queueWaiter = $0 }
    }
    func close() async throws { }
}

private struct Machine: VirtualMachine {
    let name = "vm-1"
    let canStart = true
    func start() async throws { }
    func clone(named name: String) async throws -> VirtualMachine { self }
    func delete() async throws { }
    func getIPAddress() async throws -> String { "127.0.0.1" }
}

private struct Configuration: GitHubActionsRunnerConfiguration {
    let runnerDisableDefaultLabels = false
    let runnerDisableUpdates = false
    let runnerScope = GitHubRunnerScope.organization
    let runnerLabels = "ci"
    let runnerGroup = "Default"
    let runnerName = ""
}

private struct SilentLogger: Logger {
    func info(_ message: String) { }
    func error(_ message: String) { }
}

private final class RunnerCredentials: GitHubCredentialsStore {
    let organizationName: String?
    init(organizations: String = "a,b") { organizationName = organizations }
    var repositoryName: String? { nil }
    var ownerName: String? { nil }
    var appId: String? { nil }
    var privateKey: Data? { nil }
    func setOrganizationName(_ name: String?) { }
    func setRepository(_ name: String?, withOwner owner: String?) { }
    func setAppID(_ id: String?) { }
    func setPrivateKey(_ data: Data?) { }
}

final class GitHubRunnerWaitTests: XCTestCase {
    private let idle = GitHubRunnerStatus(id: 1, name: "vm-1", busy: false)
    private let busy = GitHubRunnerStatus(id: 1, name: "vm-1", busy: true)

    private func wait(client: RunnerClient, connection: Connection) async throws {
        let handler = GitHubActionsRunnerSSHConnectionHandler(
            logger: SilentLogger(), client: client,
            credentialsStore: RunnerCredentials(), configuration: Configuration()
        )
        try await handler.waitForJob(on: Machine(), through: connection, target: .organization("a"),
                                     token: GitHubAppAccessToken("test"), timeout: .zero, pollInterval: .zero)
    }

    func testBusyRunnerIsNeverRemovedOrShutDown() async throws {
        let client = RunnerClient(statuses: [busy])
        let connection = Connection()
        try await wait(client: client, connection: connection)
        let removals = await client.removals
        let commands = await connection.commands
        XCTAssertEqual(removals, 0)
        XCTAssertEqual(commands, [])
    }

    func testIdleRunnerIsRemovedBeforeTimedOutVMIsShutDown() async throws {
        let client = RunnerClient(statuses: [idle])
        let connection = Connection()
        do {
            try await wait(client: client, connection: connection)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The runner did not receive a job within five minutes")
        }
        let removals = await client.removals
        let commands = await connection.commands
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(commands, ["sudo shutdown -h now"])
    }

    func testJobAssignedDuringRemovalIsAllowedToFinish() async throws {
        let client = RunnerClient(statuses: [idle, busy], removalFails: true)
        let connection = Connection()
        try await wait(client: client, connection: connection)
        let commands = await connection.commands
        XCTAssertEqual(commands, [])
    }

    func testRemovalFailureKeepsVMAliveUntilItsStateCanBeConfirmed() async throws {
        let client = RunnerClient(statuses: [idle, idle, busy], removalFails: true)
        let connection = Connection()
        try await wait(client: client, connection: connection)
        let commands = await connection.commands
        XCTAssertEqual(commands, [])
    }

    func testMonitoringFailureDoesNotShutDownAPotentiallyRunningJob() async throws {
        let client = RunnerClient(statuses: [busy], lookupFailures: 1)
        let connection = Connection()
        try await wait(client: client, connection: connection)
        let commands = await connection.commands
        XCTAssertEqual(commands, [])
    }
    func testRegistersAllOrganizationsBeforeSelectingAndStartingOne() async throws {
        let client = RunnerClient(statuses: [busy])
        let connection = Connection()
        await client.observeQueue(through: connection)
        let handler = GitHubActionsRunnerSSHConnectionHandler(
            logger: SilentLogger(), client: client, credentialsStore: RunnerCredentials(),
            configuration: Configuration(), scheduler: GitHubOrganizationScheduler(client: client)
        )
        try await handler.didConnect(to: Machine(), through: connection)
        let commands = await connection.commands
        let scripts = commands.filter { $0.hasPrefix("cat >") }
        XCTAssertEqual(scripts.count, 3)
        XCTAssertTrue(scripts[0].contains("https://github.com/a"))
        XCTAssertTrue(scripts[1].contains("https://github.com/b"))
        XCTAssertFalse(scripts[0].contains("./run.sh"))
        XCTAssertFalse(scripts[1].contains("./run.sh"))
        XCTAssertFalse(scripts[0].contains("trap onexit EXIT"))
        XCTAssertEqual(commands.filter { $0 == "/bin/zsh -l ~/start-runner.sh" }.count, 2)
        let queueCheck = try XCTUnwrap(commands.firstIndex(of: "# queue checked"))
        let lastRegistration = try XCTUnwrap(commands.lastIndex(of: "/bin/zsh -l ~/start-runner.sh"))
        XCTAssertLessThan(lastRegistration, queueCheck)
        let removal = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("rm -rf") })
        XCTAssertTrue(commands[removal].hasSuffix("/org-0\""))
        XCTAssertTrue(scripts[2].contains("/org-1"))
        XCTAssertTrue(scripts[2].contains("/bin/bash ./env.sh"))
        XCTAssertTrue(scripts[2].contains("./run.sh"))
        XCTAssertFalse(scripts[2].contains("fixture-registration-token"))
        let launch = try XCTUnwrap(commands.firstIndex(of: "open -a Terminal ~/start-runner.sh"))
        XCTAssertLessThan(removal, launch)
        XCTAssertEqual(commands.filter { $0.hasPrefix("open -a Terminal") }.count, 1)
        XCTAssertFalse(commands.contains { $0.contains("\\\"") })
    }

    func testSingleOrganizationKeepsConfigureAndStartBehavior() async throws {
        let client = RunnerClient(statuses: [])
        let connection = Connection()
        let handler = GitHubActionsRunnerSSHConnectionHandler(
            logger: SilentLogger(), client: client,
            credentialsStore: RunnerCredentials(organizations: "a"), configuration: Configuration()
        )
        try await handler.didConnect(to: Machine(), through: connection)
        let commands = await connection.commands
        let scripts = commands.filter { $0.hasPrefix("cat >") }
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("ACTIONS_RUNNER_DIRECTORY=~/actions-runner"))
        XCTAssertTrue(scripts[0].contains("./config.sh"))
        XCTAssertTrue(scripts[0].contains("./run.sh"))
        XCTAssertTrue(scripts[0].contains("trap onexit EXIT"))
        XCTAssertFalse(commands.contains("/bin/zsh -l ~/start-runner.sh"))
        XCTAssertEqual(commands.last, "open -a Terminal ~/start-runner.sh")
    }

    func testNoJobsRegistersOfflineRunnersWithoutStartingListener() async throws {
        let client = RunnerClient(statuses: [], hasJobs: false)
        let connection = Connection()
        await client.observeQueue(through: connection)
        let handler = GitHubActionsRunnerSSHConnectionHandler(
            logger: SilentLogger(), client: client, credentialsStore: RunnerCredentials(),
            configuration: Configuration(), scheduler: GitHubOrganizationScheduler(client: client)
        )
        let task = Task { try await handler.didConnect(to: Machine(), through: connection) }
        await connection.waitForQueueCheck()
        let commands = await connection.commands
        XCTAssertEqual(commands.filter { $0 == "/bin/zsh -l ~/start-runner.sh" }.count, 2)
        XCTAssertFalse(commands.contains { $0.hasPrefix("open -a Terminal") })
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation of the idle VM")
        } catch is CancellationError { }
    }

}
