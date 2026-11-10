import Foundation
import GitHubDomain
import NetworkingDomain

private struct InstallationRepositories: Decodable {
    struct Repository: Decodable {
        let full_name: String
    }
    let repositories: [Repository]
}

private struct WorkflowRuns: Decodable {
    struct Run: Decodable {
        let id: Int
    }
    let total_count: Int
    let workflow_runs: [Run]
}

private struct WorkflowJobs: Decodable {
    struct Job: Decodable {
        let status: String
        let labels: [String]
    }
    let jobs: [Job]
}

private struct OrganizationRunners: Decodable {
    let runners: [GitHubRunnerStatus]
}

private enum QueueRequestError: LocalizedError {
    case tooManyWorkflowRuns(String)
    case invalidPaginationLink

    var errorDescription: String? {
        switch self {
        case .invalidPaginationLink:
            "GitHub returned an invalid pagination link."
        case let .tooManyWorkflowRuns(repository):
            "More than 1,000 active workflow runs in \(repository); GitHub search cannot return all of them."
        }
    }
}

extension NetworkingGitHubClient {
    public func getQueuedJobCount(
        with token: GitHubAppAccessToken,
        target: GitHubRunnerTarget,
        labels: Set<String>
    ) async throws -> Int {
        let request = makeRequest(path: "/installation/repositories", token: token)
        let repositories = try await pages(request: request) { (page: InstallationRepositories) in page.repositories }
        var count = 0
        for repository in repositories {
            // A running workflow may still have queued matrix jobs or dependent jobs.
            var runIDs = Set<Int>()
            for status in ["queued", "in_progress"] {
                var request = makeRequest(path: "/repos/\(repository.full_name)/actions/runs", token: token)
                request.url?.append(queryItems: [URLQueryItem(name: "status", value: status)])
                let runs = try await pages(request: request) { (page: WorkflowRuns) in
                    guard page.total_count <= 1_000 else {
                        throw QueueRequestError.tooManyWorkflowRuns(repository.full_name)
                    }
                    return page.workflow_runs
                }
                runIDs.formUnion(runs.map(\.id))
            }
            for runID in runIDs {
                let request = makeRequest(
                    path: "/repos/\(repository.full_name)/actions/runs/\(runID)/jobs", token: token
                )
                let jobs = try await pages(request: request) { (page: WorkflowJobs) in page.jobs }
                count += jobs.filter { job in
                    job.status == "queued"
                        && Set(job.labels.map { $0.lowercased() }).isSubset(of: labels)
                }.count
            }
        }
        return count
    }

    public func getRunner(
        with token: GitHubAppAccessToken,
        target: GitHubRunnerTarget,
        name: String
    ) async throws -> GitHubRunnerStatus? {
        let request = makeRequest(path: target.apiPath + "/actions/runners", token: token)
        return try await pages(request: request) { (page: OrganizationRunners) in page.runners }
            .first { $0.name == name }
    }

    public func removeRunner(
        with token: GitHubAppAccessToken,
        target: GitHubRunnerTarget,
        id: Int
    ) async throws {
        var request = makeRequest(path: target.apiPath + "/actions/runners/\(id)", token: token)
        request.httpMethod = "DELETE"
        _ = try await networkingService.data(from: request).map(\.value)
    }

    private func makeRequest(path: String, token: GitHubAppAccessToken) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(token.rawValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    func pages<Page: Decodable, Item>(
        request: URLRequest,
        items: (Page) throws -> [Item]
    ) async throws -> [Item] {
        var request = request
        request.url?.append(queryItems: [URLQueryItem(name: "per_page", value: "100")])
        var result: [Item] = []
        while true {
            try Task.checkCancellation()
            let response = await networkingService.load(Page.self, from: request)
            result += try response.map { try items($0.value) }
            let links = response.httpURLResponse?.value(forHTTPHeaderField: "Link") ?? ""
            guard let next = links.split(separator: ",").first(where: { $0.contains("rel=\"next\"") }) else {
                return result
            }
            guard let start = next.firstIndex(of: "<"), let end = next.firstIndex(of: ">"), start < end,
                  let url = URL(string: String(next[next.index(after: start)..<end])),
                  url.scheme == baseURL.scheme, url.host == baseURL.host else {
                throw QueueRequestError.invalidPaginationLink
            }
            request.url = url
        }
    }
}
