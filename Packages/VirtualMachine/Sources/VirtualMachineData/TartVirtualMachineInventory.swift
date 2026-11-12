import VirtualMachineDomain

public struct TartVirtualMachineInventory: VirtualMachineInventory {
    private let tart: Tart

    public init(tart: Tart) {
        self.tart = tart
    }

    public func state(ofVirtualMachineNamed name: String) async throws -> ExistingVirtualMachineState {
        guard let virtualMachine = try await tart.localVirtualMachines().first(where: { $0.name == name }) else {
            return .absent
        }
        return virtualMachine.isRunning ? .running : .stopped
    }

    public func deleteVirtualMachine(named name: String) async throws {
        try await tart.delete(name: name)
    }
}
