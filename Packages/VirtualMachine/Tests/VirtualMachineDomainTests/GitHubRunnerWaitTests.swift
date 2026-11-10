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
    var lookupFailures: Int
    private(set) var removals = 0

    init(statuses: [GitHubRunnerStatus?], removalFails: Bool = false, lookupFailures: Int = 0) {
        self.statuses = statuses
        self.removalFails = removalFails
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
        fatalError("Not used while waiting")
    }
    func getQueuedJobCount(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                           labels: Set<String>) async throws -> Int { fatalError("Not used while waiting") }
    func getRunnerRegistrationToken(with token: GitHubAppAccessToken,
                                    target: GitHubRunnerTarget) async throws -> GitHubRunnerRegistrationToken {
        fatalError("Not used while waiting")
    }
    func getRunnerDownloadURL(with token: GitHubAppAccessToken,
                              target: GitHubRunnerTarget) async throws -> URL { fatalError("Not used while waiting") }
}

private actor Connection: SSHConnection {
    private(set) var commands: [String] = []
    func executeCommand(_ command: String) async throws { commands.append(command) }
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
    var organizationName: String? { "a,b" }
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
}
