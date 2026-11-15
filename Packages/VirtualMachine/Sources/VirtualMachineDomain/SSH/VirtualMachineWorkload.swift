import SSHDomain

public protocol VirtualMachineWorkload {
    func prepare(on virtualMachine: VirtualMachine, through connection: SSHConnection) async throws
        -> PreparedVirtualMachineWorkload
}

public struct PreparedVirtualMachineWorkload {
    private let operation: (SSHConnection) async throws -> Void

    public init(run operation: @escaping (SSHConnection) async throws -> Void) {
        self.operation = operation
    }

    public func run(through connection: SSHConnection) async throws {
        try await operation(connection)
    }
}
