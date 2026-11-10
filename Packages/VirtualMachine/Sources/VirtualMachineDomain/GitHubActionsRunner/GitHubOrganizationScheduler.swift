import Foundation
import GitHubDomain

public actor GitHubOrganizationScheduler {
    private let client: GitHubClient
    private var queue = GitHubOrganizationQueue()
    private var queuedJobs: [String: Int] = [:]
    private var refreshedAt = Date.distantPast
    private var isRefreshing = false

    public init(client: GitHubClient) {
        self.client = client
    }

    public func nextOrganization(slot: String, organizations: [String], labels: Set<String>) async throws -> String? {
        try Task.checkCancellation()
        guard !isRefreshing else { return nil }
        if Date().timeIntervalSince(refreshedAt) >= 30 {
            isRefreshing = true
            defer { isRefreshing = false }
            var counts: [String: Int] = [:]
            for organization in organizations {
                let target = GitHubRunnerTarget.organization(organization)
                let token = try await client.getAppAccessToken(target: target)
                counts[organization] = try await client.getQueuedJobCount(with: token, target: target, labels: labels)
            }
            try Task.checkCancellation()
            queuedJobs = counts
            refreshedAt = Date()
        }
        try Task.checkCancellation()
        return queue.reserve(slot: slot, organizations: organizations, queuedJobs: queuedJobs)
    }

    public func didStartJob(slot: String) {
        queue.didStartJob(slot: slot)
        // The previous queued count may still include the job that just started.
        queuedJobs = [:]
        refreshedAt = .distantPast
    }

    public func release(slot: String) {
        queue.release(slot: slot)
        queuedJobs = [:]
        refreshedAt = .distantPast
    }
}
