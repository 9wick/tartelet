import GitHubDomain
@testable import VirtualMachineDomain
import XCTest

final class GitHubOrganizationQueueTests: XCTestCase {
    func testRoundRobinSkipsOrganizationsWithoutMatchingJobs() {
        var queue = GitHubOrganizationQueue()
        let organizations = ["a", "empty", "b"]
        let jobs = ["a": 3, "b": 3]
        XCTAssertEqual(queue.reserve(slot: "1", organizations: organizations, queuedJobs: jobs), "a")
        XCTAssertEqual(queue.reserve(slot: "2", organizations: organizations, queuedJobs: jobs), "b")
        queue.release(slot: "1")
        XCTAssertEqual(queue.reserve(slot: "1", organizations: organizations, queuedJobs: jobs), "a")
    }

    func testTwoSlotsCannotReserveOneWaitingJob() {
        var queue = GitHubOrganizationQueue()
        XCTAssertEqual(queue.reserve(slot: "1", organizations: ["a"], queuedJobs: ["a": 1]), "a")
        XCTAssertNil(queue.reserve(slot: "2", organizations: ["a"], queuedJobs: ["a": 1]))
        XCTAssertNil(queue.reserve(slot: "1", organizations: ["a"], queuedJobs: ["a": 2]))
    }

    func testTwoQueuedJobsCanUseBothSlotsInOneOrganization() {
        var queue = GitHubOrganizationQueue()
        XCTAssertEqual(queue.reserve(slot: "1", organizations: ["a"], queuedJobs: ["a": 2]), "a")
        XCTAssertEqual(queue.reserve(slot: "2", organizations: ["a"], queuedJobs: ["a": 2]), "a")
    }

    func testRunningJobDoesNotConsumeNewQueuedDemand() {
        var queue = GitHubOrganizationQueue()
        _ = queue.reserve(slot: "1", organizations: ["a"], queuedJobs: ["a": 1])
        queue.didStartJob(slot: "1")
        XCTAssertEqual(queue.reserve(slot: "2", organizations: ["a"], queuedJobs: ["a": 1]), "a")
    }

    func testReleaseAllowsReplacementVMToReserveAgain() {
        var queue = GitHubOrganizationQueue()
        _ = queue.reserve(slot: "1", organizations: ["a"], queuedJobs: ["a": 1])
        queue.release(slot: "1")
        XCTAssertEqual(queue.reserve(slot: "1", organizations: ["a"], queuedJobs: ["a": 1]), "a")
    }

    func testNoDemandAndEmptyConfigurationDoNotReserve() {
        var queue = GitHubOrganizationQueue()
        XCTAssertNil(queue.reserve(slot: "1", organizations: [], queuedJobs: [:]))
        XCTAssertNil(queue.reserve(slot: "1", organizations: ["a"], queuedJobs: [:]))
    }

    func testOrganizationNamesAreTrimmedAndDeduplicatedWithoutChangingOrder() {
        XCTAssertEqual(GitHubOrganizationNames.parse(" org-a,Org-B,ORG-A,, "), ["org-a", "Org-B"])
        XCTAssertEqual(GitHubOrganizationNames.parse(" , "), [])
    }
}
