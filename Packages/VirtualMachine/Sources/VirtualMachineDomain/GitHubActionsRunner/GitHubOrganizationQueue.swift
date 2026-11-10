import Foundation

struct GitHubOrganizationQueue {
    struct Reservation {
        let organization: String
        var isRunning = false
    }

    private(set) var reservations: [String: Reservation] = [:]
    private var lastOrganization: String?

    mutating func reserve(slot: String, organizations: [String], queuedJobs: [String: Int]) -> String? {
        guard reservations[slot] == nil, !organizations.isEmpty else { return nil }
        let start = lastOrganization.flatMap { organizations.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for offset in 0..<organizations.count {
            let organization = organizations[(start + offset) % organizations.count]
            let pending = reservations.values.filter { $0.organization == organization && !$0.isRunning }.count
            if queuedJobs[organization, default: 0] > pending {
                reservations[slot] = Reservation(organization: organization)
                lastOrganization = organization
                return organization
            }
        }
        return nil
    }

    mutating func didStartJob(slot: String) {
        reservations[slot]?.isRunning = true
    }

    mutating func release(slot: String) {
        reservations.removeValue(forKey: slot)
    }
}
