import Foundation
@testable import VirtualMachineData
import XCTest

final class SharedCacheAccessTests: XCTestCase {
    private let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".tmp/cache-access-\(UUID().uuidString)")
    private var lease: URL { folder.appendingPathComponent("github-actions-cache-server/writer.lock") }
    private var snapshot: URL { folder.appendingPathComponent("github-actions-cache-server/CURRENT") }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: true)
        try Data("old-owner".utf8).write(to: lease.appendingPathComponent("owner"))
        try Data("committed-generation".utf8).write(to: snapshot)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testStoppedMachinesAllowRecoveryWithoutChangingSnapshot() throws {
        let access = try SharedCacheAccess(cacheFolder: folder)
        try access.prepare(hasRunningVirtualMachines: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path))
        XCTAssertEqual(try String(contentsOf: snapshot), "committed-generation")
    }

    func testRunningMachinePreservesLease() throws {
        let access = try SharedCacheAccess(cacheFolder: folder)
        try access.prepare(hasRunningVirtualMachines: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.path))
    }

    func testStartupReservationExcludesAnotherRecovery() throws {
        let access = try SharedCacheAccess(cacheFolder: folder)
        defer { withExtendedLifetime(access) {} }
        XCTAssertThrowsError(try SharedCacheAccess(cacheFolder: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.path))
    }

    func testActiveReservationPreservesLeaseEvenBeforeTartReportsRunning() throws {
        var first: SharedCacheAccess? = try SharedCacheAccess(cacheFolder: folder)
        try first?.prepare(hasRunningVirtualMachines: true)
        var second: SharedCacheAccess? = try SharedCacheAccess(cacheFolder: folder)
        XCTAssertEqual(second?.canRecover, false)
        try second?.prepare(hasRunningVirtualMachines: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.path))
        first = nil
        second = nil
        let restarted = try SharedCacheAccess(cacheFolder: folder)
        XCTAssertTrue(restarted.canRecover)
        try restarted.prepare(hasRunningVirtualMachines: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path))
    }

    func testAbsentLeaseDoesNotPreventStartup() throws {
        try FileManager.default.removeItem(at: lease)
        let access = try SharedCacheAccess(cacheFolder: folder)
        try access.prepare(hasRunningVirtualMachines: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path))
    }
}
