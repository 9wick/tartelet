import LoggingDomain
@testable import VirtualMachineDomain
import XCTest

private actor Inventory: VirtualMachineInventory {
    let existing: ExistingVirtualMachineState
    private(set) var deletedNames: [String] = []

    init(existing: ExistingVirtualMachineState) {
        self.existing = existing
    }

    func state(ofVirtualMachineNamed name: String) async throws -> ExistingVirtualMachineState {
        existing
    }

    func deleteVirtualMachine(named name: String) async throws {
        deletedNames.append(name)
    }
}

private final class RecordingLogger: Logger, @unchecked Sendable {
    private(set) var messages: [String] = []
    func info(_ message: String) { messages.append(message) }
    func error(_ message: String) { messages.append(message) }
}

final class LeftoverVirtualMachineTests: XCTestCase {
    func testSlotIsReadyWithoutDeletingWhenNoVirtualMachineExists() async throws {
        let inventory = Inventory(existing: .absent)
        let logger = RecordingLogger()

        let isReady = try await removeLeftoverVirtualMachine(named: "vm-1", inventory: inventory, logger: logger)

        XCTAssertTrue(isReady)
        let deletedNames = await inventory.deletedNames
        XCTAssertEqual(deletedNames, [])
    }

    func testStoppedLeftoverIsDeletedAndLogged() async throws {
        let inventory = Inventory(existing: .stopped)
        let logger = RecordingLogger()

        let isReady = try await removeLeftoverVirtualMachine(named: "vm-1", inventory: inventory, logger: logger)

        XCTAssertTrue(isReady)
        let deletedNames = await inventory.deletedNames
        XCTAssertEqual(deletedNames, ["vm-1"])
        XCTAssertTrue(logger.messages.contains { $0.contains("vm-1") })
    }

    func testRunningVirtualMachineIsKeptAndSlotIsNotReady() async throws {
        let inventory = Inventory(existing: .running)
        let logger = RecordingLogger()

        let isReady = try await removeLeftoverVirtualMachine(named: "vm-1", inventory: inventory, logger: logger)

        XCTAssertFalse(isReady)
        let deletedNames = await inventory.deletedNames
        XCTAssertEqual(deletedNames, [])
        XCTAssertTrue(logger.messages.contains { $0.contains("vm-1") })
    }
}
