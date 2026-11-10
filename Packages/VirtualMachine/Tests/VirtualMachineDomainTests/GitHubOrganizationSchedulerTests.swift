import GitHubDomain
@testable import VirtualMachineDomain
import XCTest

private enum TestError: Error {
    case denied
}

private actor QueueClient: GitHubClient {
    var denied = false
    private(set) var countRequests = 0

    func denyAccess() { denied = true }
    func getAppAccessToken(target: GitHubRunnerTarget) async throws -> GitHubAppAccessToken {
        if denied { throw TestError.denied }
        return GitHubAppAccessToken("test")
    }
    func getQueuedJobCount(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                           labels: Set<String>) async throws -> Int {
        countRequests += 1
        await Task.yield()
        return 1
    }
    func getRunnerRegistrationToken(with token: GitHubAppAccessToken,
                                    target: GitHubRunnerTarget) async throws -> GitHubRunnerRegistrationToken {
        fatalError("Not used by scheduling")
    }
    func getRunnerDownloadURL(with token: GitHubAppAccessToken,
                              target: GitHubRunnerTarget) async throws -> URL {
        fatalError("Not used by scheduling")
    }
    func getRunner(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                   name: String) async throws -> GitHubRunnerStatus? {
        fatalError("Not used by scheduling")
    }
    func removeRunner(with token: GitHubAppAccessToken, target: GitHubRunnerTarget, id: Int) async throws {
        fatalError("Not used by scheduling")
    }
}

final class GitHubOrganizationSchedulerTests: XCTestCase {
    func testConcurrentWaitersDoNotReserveTheSameDemand() async throws {
        let client = QueueClient()
        let scheduler = GitHubOrganizationScheduler(client: client)
        async let first = scheduler.nextOrganization(slot: "1", organizations: ["a"], labels: [])
        async let second = scheduler.nextOrganization(slot: "2", organizations: ["a"], labels: [])
        let initial = try await [first, second]
        XCTAssertEqual(initial.compactMap { $0 }.count, 1)
        let waitingSlot = initial[0] == nil ? "1" : "2"
        let next = try await scheduler.nextOrganization(slot: waitingSlot, organizations: ["a"], labels: [])
        XCTAssertNil(next)
        let requests = await client.countRequests
        XCTAssertEqual(requests, 1)
    }

    func testPermissionErrorsPropagateWithoutCreatingReservations() async throws {
        let client = QueueClient()
        await client.denyAccess()
        let scheduler = GitHubOrganizationScheduler(client: client)
        do {
            _ = try await scheduler.nextOrganization(slot: "1", organizations: ["a"], labels: [])
            XCTFail("Expected an authentication error")
        } catch TestError.denied {
            // Authentication failures must not become an empty queue.
        }
    }

    func testCanceledWaiterDoesNotReserveCapacity() async throws {
        let scheduler = GitHubOrganizationScheduler(client: QueueClient())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scheduler.nextOrganization(slot: "1", organizations: ["a"], labels: [])
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let next = try await scheduler.nextOrganization(slot: "1", organizations: ["a"], labels: [])
            XCTAssertEqual(next, "a")
        }
    }
}
