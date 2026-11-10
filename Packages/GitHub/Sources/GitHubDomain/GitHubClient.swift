import Foundation

public protocol GitHubClient {
    func getAppAccessToken(target: GitHubRunnerTarget) async throws -> GitHubAppAccessToken
    func getRunnerRegistrationToken(
        with appAccessToken: GitHubAppAccessToken,
        target: GitHubRunnerTarget
    ) async throws -> GitHubRunnerRegistrationToken
    func getRunnerDownloadURL(
        with appAccessToken: GitHubAppAccessToken,
        target: GitHubRunnerTarget
    ) async throws -> URL
    func getQueuedJobCount(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                           labels: Set<String>) async throws -> Int
    func getRunner(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                   name: String) async throws -> GitHubRunnerStatus?
    func removeRunner(with token: GitHubAppAccessToken, target: GitHubRunnerTarget,
                      id: Int) async throws
}
