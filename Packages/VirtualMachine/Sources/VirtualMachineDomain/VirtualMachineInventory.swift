import LoggingDomain

public enum ExistingVirtualMachineState: Equatable {
    case absent
    case stopped
    case running
}

/// Reads the virtualization tool's actual state, which is the single source of truth
/// for whether a slot's machine exists.
public protocol VirtualMachineInventory {
    func state(ofVirtualMachineNamed name: String) async throws -> ExistingVirtualMachineState
    func deleteVirtualMachine(named name: String) async throws
}

/// Returns whether the slot is free to clone into.
/// A stopped machine is a leftover from an earlier run that ended without cleanup, so it is safe to delete.
/// A running machine may still be executing a job, so it is never deleted here.
func removeLeftoverVirtualMachine(
    named name: String,
    inventory: VirtualMachineInventory,
    logger: Logger
) async throws -> Bool {
    do {
        switch try await inventory.state(ofVirtualMachineNamed: name) {
        case .absent:
            return true
        case .stopped:
            logger.info("Deleting leftover stopped virtual machine named \(name)")
            try await inventory.deleteVirtualMachine(named: name)
            return true
        case .running:
            logger.info("Virtual machine named \(name) is already running, so it will be checked again later")
            return false
        }
    } catch {
        logger.error("Could not remove leftover virtual machine named \(name): " + error.localizedDescription)
        throw error
    }
}
