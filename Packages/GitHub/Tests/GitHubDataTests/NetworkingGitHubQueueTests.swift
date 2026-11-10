import Foundation
import GitHubData
import GitHubDomain
import NetworkingDomain
import XCTest

private enum FixtureError: Error {
    case unexpectedRequest(String)
    case denied
}

private struct FixtureNetwork: NetworkingService {
    let respond: (URLRequest) throws -> (String, String?)

    func data(from request: URLRequest) async -> NetworkResponse<Data> {
        do {
            let (body, next) = try respond(request)
            let headers = next.map { ["Link": "<\($0)>; rel=\"next\""] }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: headers)
            return .success(with: Data(body.utf8), httpURLResponse: response)
        } catch {
            return .failure(withError: error)
        }
    }

    func load<T: Decodable>(_ valueType: T.Type, from request: URLRequest) async -> NetworkResponse<T> {
        await data(from: request).map { parameters in
            .success(with: try JSONDecoder().decode(T.self, from: parameters.value),
                     httpURLResponse: parameters.httpURLResponse)
        }
    }
}

private final class Credentials: GitHubCredentialsStore {
    var organizationName: String? = "a,b"
    var repositoryName: String?
    var ownerName: String?
    var appId: String?
    var privateKey: Data?
    func setOrganizationName(_ name: String?) { organizationName = name }
    func setRepository(_ name: String?, withOwner owner: String?) { repositoryName = name; ownerName = owner }
    func setAppID(_ id: String?) { appId = id }
    func setPrivateKey(_ data: Data?) { privateKey = data }
}

final class NetworkingGitHubQueueTests: XCTestCase {
    func testCountsMatchingQueuedJobsAcrossPagesAndRunningWorkflows() async throws {
        let network = FixtureNetwork { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = query.first { $0.name == "page" }?.value
            switch url.path {
            case "/installation/repositories":
                if page == "2" { return (#"{"repositories":[{"full_name":"a/second"}]}"#, nil) }
                return (#"{"repositories":[{"full_name":"a/first"}]}"#,
                        "https://api.github.com/installation/repositories?per_page=100&page=2")
            case "/repos/a/first/actions/runs", "/repos/a/second/actions/runs":
                // Returning the same ID for both statuses models a workflow changing state during polling.
                return (#"{"total_count":1,"workflow_runs":[{"id":10}]}"#, nil)
            case "/repos/a/first/actions/runs/10/jobs", "/repos/a/second/actions/runs/10/jobs":
                if page == "2" {
                    return (#"{"jobs":[{"status":"queued","labels":["self-hosted","macOS","ci"]}]}"#, nil)
                }
                return (#"""
                        {"jobs":[
                          {"status":"in_progress","labels":["ci"]},
                          {"status":"queued","labels":["ubuntu-latest"]},
                          {"status":"completed","labels":["ci"]}
                        ]}
                        """#,
                        "https://api.github.com\(url.path)?per_page=100&page=2")
            default:
                throw FixtureError.unexpectedRequest(url.absoluteString)
            }
        }
        let client = NetworkingGitHubClient(credentialsStore: Credentials(), networkingService: network)
        let count = try await client.getQueuedJobCount(
            with: GitHubAppAccessToken("token"), target: .organization("a"), labels: ["self-hosted", "macos", "ci"]
        )
        XCTAssertEqual(count, 2)
    }

    func testRunnerLookupFollowsPaginationAndUsesExplicitOrganization() async throws {
        let network = FixtureNetwork { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/orgs/b/actions/runners")
            if url.query?.contains("page=2") == true {
                return (#"{"runners":[{"id":2,"name":"vm-2","busy":true}]}"#, nil)
            }
            return (#"{"runners":[{"id":1,"name":"vm-1","busy":false}]}"#,
                    "https://api.github.com/orgs/b/actions/runners?per_page=100&page=2")
        }
        let client = NetworkingGitHubClient(credentialsStore: Credentials(), networkingService: network)
        let runner = try await client.getRunner(with: GitHubAppAccessToken("token"),
                                                target: .organization("b"), name: "vm-2")
        XCTAssertEqual(runner?.id, 2)
        XCTAssertEqual(runner?.busy, true)
    }

    func testPermissionFailureIsNotAnEmptyQueue() async throws {
        let network = FixtureNetwork { _ in throw FixtureError.denied }
        let client = NetworkingGitHubClient(credentialsStore: Credentials(), networkingService: network)
        do {
            _ = try await client.getQueuedJobCount(with: GitHubAppAccessToken("token"),
                                                   target: .organization("a"), labels: [])
            XCTFail("Expected permission failure")
        } catch FixtureError.denied {
            // Preserve the API error rather than reporting zero queued jobs.
        }
    }
}
