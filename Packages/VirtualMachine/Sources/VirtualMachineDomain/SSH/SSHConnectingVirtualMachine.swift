import Foundation
import LoggingDomain
import SSHDomain

private enum StartVirtualMachineValue {
    case virtualMachineTerminated
    case sshConnectionCompleted
}

private enum StartVirtualMachineError: LocalizedError, CustomDebugStringConvertible {
    case failedStartingVirtualMachine(Error)
    case failedEstablishingSSHConnection(Error)
    case failedPreparingWorkload(Error)
    case failedRunningWorkload(Error)
    case cancelled

    var errorDescription: String? {
        debugDescription
    }

    var debugDescription: String {
        switch self {
        case .failedStartingVirtualMachine:
            "Failed starting virtual machine"
        case .failedEstablishingSSHConnection:
            "Failed establishing SSH connection"
        case .failedPreparingWorkload:
            "Failed preparing virtual machine workload"
        case .failedRunningWorkload:
            "Failed running virtual machine workload"
        case .cancelled:
            "Task was cancelled"
        }
    }
}

private typealias StartVirtualMachineResult = Result<StartVirtualMachineValue, StartVirtualMachineError>

public final class SSHConnectingVirtualMachine<SSHClientType: SSHClient>: VirtualMachine {
    public var name: String {
        virtualMachine.name
    }
    public var canStart: Bool {
        virtualMachine.canStart
    }

    private let logger: Logger
    private let virtualMachine: VirtualMachine
    private let sshClient: VirtualMachineSSHClient<SSHClientType>
    private let workload: VirtualMachineWorkload?

    public init(
        logger: Logger,
        virtualMachine: VirtualMachine,
        sshClient: VirtualMachineSSHClient<SSHClientType>,
        workload: VirtualMachineWorkload? = nil
    ) {
        self.logger = logger
        self.virtualMachine = virtualMachine
        self.sshClient = sshClient
        self.workload = workload
    }

    public func start() async throws {
        try await withThrowingTaskGroup(of: StartVirtualMachineResult.self) { group in
            group.addTask {
                return try await self.startVirtualMachine()
            }
            group.addTask {
                return try await self.connect(to: self.virtualMachine)
            }
            for try await result in group {
                switch result {
                case let .success(value):
                    switch value {
                    case .virtualMachineTerminated:
                        // In the happy path, the SSH connection has already been established,
                        // but we'll cancel it in the odd case that it hasn't.
                        group.cancelAll()
                    case .sshConnectionCompleted:
                        // Nothing to do. The virtual machine should keep running.
                        break
                    }
                case let .failure(error):
                    switch error {
                    case .failedStartingVirtualMachine, .failedEstablishingSSHConnection,
                         .failedPreparingWorkload, .failedRunningWorkload:
                        // Only terminal phase failures reach here. Recoverable job-waiting errors
                        // are handled by the workload without cancelling the running VM.
                        group.cancelAll()
                        throw error
                    case .cancelled:
                        // The operation was canceled, so there's nothing left for us to do.
                        break
                    }
                }
            }
        }
    }

    public func clone(named newName: String) async throws -> VirtualMachine {
        let virtualMachine = try await virtualMachine.clone(named: newName)
        return SSHConnectingVirtualMachine(
            logger: logger,
            virtualMachine: virtualMachine,
            sshClient: sshClient,
            workload: workload
        )
    }

    public func delete() async throws {
        try await virtualMachine.delete()
    }

    public func getIPAddress() async throws -> String {
        try await virtualMachine.getIPAddress()
    }
}

private extension SSHConnectingVirtualMachine {
    private func startVirtualMachine() async throws -> StartVirtualMachineResult {
        do {
            try await self.virtualMachine.start()
            return .success(.virtualMachineTerminated)
        } catch {
            if error is CancellationError {
                return .failure(.cancelled)
            } else {
                return .failure(.failedStartingVirtualMachine(error))
            }
        }
    }

    private func connect(to virtualMachine: VirtualMachine) async throws -> StartVirtualMachineResult {
        let connection: SSHClientType.SSHConnectionType
        do {
            connection = try await sshClient.connect(to: virtualMachine)
        } catch {
            if error is CancellationError {
                return .failure(.cancelled)
            }
            logger.error(error.localizedDescription)
            logger.error("Could not connect to the virtual machine over SSH, so the virtual machine will be shut down.")
            return .failure(.failedEstablishingSSHConnection(error))
        }
        let result = await prepareAndRunWorkload(on: virtualMachine, through: connection)
        do {
            try await connection.close()
        } catch {
            // Closing the control connection must not interrupt a runner that has already started.
            logger.error("Could not close SSH connection to \(virtualMachine.name): \(error.localizedDescription)")
        }
        return result
    }

    private func prepareAndRunWorkload(
        on virtualMachine: VirtualMachine, through connection: SSHConnection
    ) async -> StartVirtualMachineResult {
        guard let workload else {
            return .success(.sshConnectionCompleted)
        }
        let prepared: PreparedVirtualMachineWorkload
        do {
            prepared = try await workload.prepare(on: virtualMachine, through: connection)
        } catch {
            if error is CancellationError {
                return .failure(.cancelled)
            }
            logger.error("Could not prepare workload in \(virtualMachine.name): \(error.localizedDescription)")
            return .failure(.failedPreparingWorkload(error))
        }
        logger.info("Virtual machine \(virtualMachine.name) is ready; starting workload phase")
        do {
            try Task.checkCancellation()
            try await prepared.run(through: connection)
            return .success(.sshConnectionCompleted)
        } catch {
            if error is CancellationError {
                return .failure(.cancelled)
            }
            logger.error("Workload in \(virtualMachine.name) failed: \(error.localizedDescription)")
            return .failure(.failedRunningWorkload(error))
        }
    }
}
