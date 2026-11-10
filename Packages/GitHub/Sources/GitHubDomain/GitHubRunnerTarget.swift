import Foundation

public enum GitHubRunnerTarget: Equatable, Sendable {
    case organization(String)
    case repository(owner: String, name: String)

    public var apiPath: String {
        switch self {
        case let .organization(name): "/orgs/\(name)"
        case let .repository(owner, name): "/repos/\(owner)/\(name)"
        }
    }

    public var url: URL? {
        switch self {
        case let .organization(name): URL(string: "https://github.com/\(name)")
        case let .repository(owner, name): URL(string: "https://github.com/\(owner)/\(name)")
        }
    }
}

public enum GitHubOrganizationNames {
    public static func parse(_ value: String) -> [String] {
        var seen = Set<String>()
        let names = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return names
    }
}

public struct GitHubRunnerStatus: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let busy: Bool

    public init(id: Int, name: String, busy: Bool) {
        self.id = id
        self.name = name
        self.busy = busy
    }
}
