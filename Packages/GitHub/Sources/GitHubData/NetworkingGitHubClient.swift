import Foundation
import GitHubDomain
import NetworkingDomain

private enum NetworkingGitHubClientError: LocalizedError {
    case organizationNameUnavailable
    case repositoryNameUnavailable
    case repositoryOwnerNameUnavailable
    case appIDUnavailable
    case privateKeyUnavailable
    case appIsNotInstalled
    case downloadNotFound(os: String, architecture: String)

    var errorDescription: String? {
        switch self {
        case .organizationNameUnavailable:
            return "The organization name is not available"
        case .repositoryNameUnavailable:
            return "The repository name is not available"
        case .repositoryOwnerNameUnavailable:
            return "The repository owner name is not available"
        case .appIDUnavailable:
            return "The app ID is not available"
        case .privateKeyUnavailable:
            return "The private key is not available"
        case .appIsNotInstalled:
            return "The GitHub app has not been installed. Please install it from the developer settings."
        case let .downloadNotFound(os, architecture):
            return "Could not find a download for \(os) (\(architecture))"
        }
    }
}

public final class NetworkingGitHubClient: GitHubClient {
    let baseURL = URL(string: "https://api.github.com")!
    private let credentialsStore: GitHubCredentialsStore
    let networkingService: NetworkingService

    public init(credentialsStore: GitHubCredentialsStore, networkingService: NetworkingService) {
        self.credentialsStore = credentialsStore
        self.networkingService = networkingService
    }

    public func getAppAccessToken(target: GitHubRunnerTarget) async throws -> GitHubAppAccessToken {
        let appInstallation = try await getAppInstallation(target: target)
        let installationID = String(appInstallation.id)
        let appID = String(appInstallation.appId)
        let url = baseURL.appending(path: "/app/installations/\(installationID)/access_tokens")
        guard let privateKey = credentialsStore.privateKey else {
            throw NetworkingGitHubClientError.privateKeyUnavailable
        }
        let jwtToken = try GitHubJWTTokenFactory.makeJWTToken(privateKey: privateKey, appID: appID)
        var request = URLRequest(url: url).addingBearerToken(jwtToken)
        request.httpMethod = "POST"
        return try await networkingService.load(
            IntermediateGitHubAppAccessToken.self,
            from: request
        ).map { parameters in
            GitHubAppAccessToken(parameters.value.token)
        }
    }

    public func getRunnerDownloadURL(
        with appAccessToken: GitHubAppAccessToken,
        target: GitHubRunnerTarget
    ) async throws -> URL {
        let url = baseURL.appending(path: target.apiPath + "/actions/runners/downloads")
        let request = URLRequest(url: url).addingBearerToken(appAccessToken.rawValue)
        let downloads = try await networkingService.load([GitHubRunnerDownload].self, from: request).map(\.value)
        let os = "osx"
        let architecture = "arm64"
        guard let download = downloads.first(where: { $0.os == os && $0.architecture == architecture }) else {
            throw NetworkingGitHubClientError.downloadNotFound(os: os, architecture: architecture)
        }
        return download.downloadURL
    }

    public func getRunnerRegistrationToken(
      with appAccessToken: GitHubAppAccessToken,
      target: GitHubRunnerTarget
    ) async throws -> GitHubRunnerRegistrationToken {
        let url = baseURL.appending(path: target.apiPath + "/actions/runners/registration-token")
        var request = URLRequest(url: url).addingBearerToken(appAccessToken.rawValue)
        request.httpMethod = "POST"
        return try await networkingService.load(
            IntermediateGitHubRunnerRegistrationToken.self,
            from: request
        ).map { parameters in
            GitHubRunnerRegistrationToken(parameters.value.token)
        }
    }
}

private extension NetworkingGitHubClient {
    private func getAppInstallation(target: GitHubRunnerTarget) async throws -> GitHubAppInstallation {
        let url = baseURL.appending(path: "/app/installations")
        let token = try await getAppJWTToken()
        let request = URLRequest(url: url).addingBearerToken(token)
        let appInstallations = try await pages(request: request) { (values: [GitHubAppInstallation]) in values }
        let loginName: String
        switch target {
        case let .organization(name): loginName = name
        case let .repository(owner, _): loginName = owner
        }
        guard let appInstallation = appInstallations.first(where: {
            $0.account.login.caseInsensitiveCompare(loginName) == .orderedSame
        }) else {
            throw NetworkingGitHubClientError.appIsNotInstalled
        }
        return appInstallation
    }

    private func getAppJWTToken() async throws -> String {
        guard let privateKey = credentialsStore.privateKey else {
            throw NetworkingGitHubClientError.privateKeyUnavailable
        }
        guard let appID = credentialsStore.appId else {
            throw NetworkingGitHubClientError.appIDUnavailable
        }
        return try GitHubJWTTokenFactory.makeJWTToken(privateKey: privateKey, appID: appID)
    }
}

private extension URLRequest {
    func addingBearerToken(_ token: String) -> URLRequest {
        var mutableRequest = self
        mutableRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return mutableRequest
    }
}
