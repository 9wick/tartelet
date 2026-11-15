import Foundation
import LoggingDomain
import SSHDomain
@testable import VirtualMachineDomain
import XCTest

private actor Events {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private struct LiveMachine: VirtualMachine {
    let name = "vm-1"
    let canStart = true
    let events: Events
    let stopped: XCTestExpectation
    let exit = AsyncStream<Void>.makeStream()

    func start() async throws {
        await events.record("vm-start")
        for await _ in exit.stream { break }
        await events.record("vm-stop")
        stopped.fulfill()
    }
    func terminate() { exit.continuation.yield(()) }
    func clone(named name: String) async throws -> VirtualMachine { self }
    func delete() async throws { await events.record("delete") }
    func getIPAddress() async throws -> String { "127.0.0.1" }
}

private struct TestConnection: SSHConnection {
    let events: Events
    let closed: XCTestExpectation
    var failsToClose = false
    func executeCommand(_ command: String) async throws { }
    func close() async throws {
        await events.record("close")
        closed.fulfill()
        if failsToClose { throw URLError(.networkConnectionLost) }
    }
}

private struct TestSSHClient: SSHClient {
    let connection: TestConnection
    func connect(host: String, username: String, password: String) async throws -> TestConnection {
        await connection.events.record("ssh")
        return connection
    }
}

private struct IPAddressReader: VirtualMachineIPAddressReader {
    func readIPAddress(of virtualMachine: VirtualMachine) async throws -> String { "127.0.0.1" }
}

private final class Credentials: VirtualMachineSSHCredentialsStore {
    var username: String? { "test" }
    var password: String? { "test" }
    func setUsername(_ username: String?) { }
    func setPassword(_ password: String?) { }
}

private struct BootHandler: VirtualMachineSSHConnectionHandler {
    let events: Events
    func didConnect(to virtualMachine: VirtualMachine, through connection: SSHConnection) async throws {
        await events.record("boot-script")
    }
}

private struct Workload: VirtualMachineWorkload {
    let events: Events
    let running: XCTestExpectation
    var waitUntilCancelled = false
    var preparationFails = false

    func prepare(on virtualMachine: VirtualMachine, through connection: SSHConnection) async throws
        -> PreparedVirtualMachineWorkload {
        await events.record("prepare")
        if preparationFails { throw URLError(.cannotConnectToHost) }
        return PreparedVirtualMachineWorkload { _ in
            await events.record("run")
            running.fulfill()
            if waitUntilCancelled { try await Task.sleep(for: .seconds(3_600)) }
        }
    }
}

private final class Log: Logger, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func info(_ message: String) { lock.lock(); defer { lock.unlock() }; values.append(message) }
    func error(_ message: String) { info(message) }
}

final class VirtualMachineWorkloadTests: XCTestCase {
    private func machine(
        underlying: LiveMachine, workload: Workload, closed: XCTestExpectation,
        logger: Log = Log(), failsToClose: Bool = false
    ) -> SSHConnectingVirtualMachine<TestSSHClient> {
        SSHConnectingVirtualMachine(
            logger: logger, virtualMachine: underlying,
            sshClient: VirtualMachineSSHClient(
                logger: logger,
                client: TestSSHClient(connection: TestConnection(
                    events: underlying.events, closed: closed, failsToClose: failsToClose
                )),
                ipAddressReader: IPAddressReader(), credentialsStore: Credentials(),
                connectionHandler: BootHandler(events: underlying.events)
            ),
            workload: workload
        )
    }

    func testPreparationPrecedesWorkloadAndClosingSSHDoesNotStopVM() async throws {
        let events = Events()
        let stopped = expectation(description: "VM stopped")
        let closed = expectation(description: "SSH closed")
        let running = expectation(description: "Workload running")
        let underlying = LiveMachine(events: events, stopped: stopped)
        let vm = machine(underlying: underlying, workload: Workload(events: events, running: running), closed: closed)
        let task = Task { try await vm.start() }
        await fulfillment(of: [running, closed], timeout: 3)
        let beforeExit = await events.values
        XCTAssertEqual(beforeExit.filter { $0 != "vm-start" }, ["ssh", "boot-script", "prepare", "run", "close"])
        XCTAssertFalse(beforeExit.contains("vm-stop"))
        XCTAssertFalse(beforeExit.contains("delete"))
        underlying.terminate()
        try await task.value
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testVMExitCancelsJobWaiting() async throws {
        let events = Events()
        let running = expectation(description: "Waiting for jobs")
        let stopped = expectation(description: "VM stopped")
        let closed = expectation(description: "SSH closed")
        let underlying = LiveMachine(events: events, stopped: stopped)
        let vm = machine(underlying: underlying,
                         workload: Workload(events: events, running: running, waitUntilCancelled: true), closed: closed)
        let task = Task { try await vm.start() }
        await fulfillment(of: [running], timeout: 3)
        underlying.terminate()
        try await task.value
        await fulfillment(of: [stopped, closed], timeout: 3)
    }

    func testExplicitCancellationStopsVMAndJobWaiting() async throws {
        let events = Events()
        let running = expectation(description: "Waiting for jobs")
        let stopped = expectation(description: "VM stopped")
        let closed = expectation(description: "SSH closed")
        let underlying = LiveMachine(events: events, stopped: stopped)
        let vm = machine(underlying: underlying,
                         workload: Workload(events: events, running: running, waitUntilCancelled: true), closed: closed)
        let task = Task { try await vm.start() }
        await fulfillment(of: [running], timeout: 3)
        task.cancel()
        try await task.value
        await fulfillment(of: [stopped, closed], timeout: 3)
    }

    func testCloseFailureAfterRunnerLaunchKeepsVMAliveAndIsLogged() async throws {
        let events = Events()
        let running = expectation(description: "Runner launched")
        let stopped = expectation(description: "VM stopped")
        let closed = expectation(description: "SSH close attempted")
        let logger = Log()
        let underlying = LiveMachine(events: events, stopped: stopped)
        let vm = machine(underlying: underlying, workload: Workload(events: events, running: running),
                         closed: closed, logger: logger, failsToClose: true)
        let task = Task { try await vm.start() }
        await fulfillment(of: [running, closed], timeout: 3)
        underlying.terminate()
        try await task.value
        XCTAssertTrue(logger.messages.contains { $0.contains("Could not close SSH connection") })
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testPreparationFailureIsNotReportedAsSSHFailureAndDoesNotStartWorkload() async throws {
        let events = Events()
        let running = XCTestExpectation(description: "Workload must not run")
        let stopped = expectation(description: "VM stopped")
        let closed = expectation(description: "SSH closed")
        let logger = Log()
        let underlying = LiveMachine(events: events, stopped: stopped)
        let vm = machine(underlying: underlying,
                         workload: Workload(events: events, running: running, preparationFails: true),
                         closed: closed, logger: logger)
        do {
            try await vm.start()
            XCTFail("Expected preparation failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Failed preparing virtual machine workload")
        }
        let values = await events.values
        XCTAssertFalse(values.contains("run"))
        XCTAssertFalse(logger.messages.contains { $0.contains("Could not connect to the virtual machine over SSH") })
        await fulfillment(of: [stopped, closed], timeout: 3)
    }
}
