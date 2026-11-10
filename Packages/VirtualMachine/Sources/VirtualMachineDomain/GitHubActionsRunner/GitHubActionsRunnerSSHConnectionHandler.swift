import Foundation
import GitHubDomain
import LoggingDomain
import SSHDomain

private enum GitHubActionsRunnerSSHConnectionHandlerError: LocalizedError {
    case organizationNameUnavailable
    case invalidRunnerURL
    case runnerWaitTimedOut

    var errorDescription: String? {
        switch self {
        case .organizationNameUnavailable:
            return "The organization name is unavailable"
        case .runnerWaitTimedOut:
            return "The runner did not receive a job within five minutes"
        case .invalidRunnerURL:
            return "The runner URL is invalid. Ensure the organization name is correct"
        }
    }
}

public struct GitHubActionsRunnerSSHConnectionHandler: VirtualMachineSSHConnectionHandler {
    private let logger: Logger
    private let client: GitHubClient
    private let credentialsStore: GitHubCredentialsStore
    private let scheduler: GitHubOrganizationScheduler?
    private let configuration: GitHubActionsRunnerConfiguration

    public init(
        logger: Logger,
        client: GitHubClient,
        credentialsStore: GitHubCredentialsStore,
        configuration: GitHubActionsRunnerConfiguration,
        scheduler: GitHubOrganizationScheduler? = nil
    ) {
        self.logger = logger
        self.client = client
        self.credentialsStore = credentialsStore
        self.configuration = configuration
        self.scheduler = scheduler
    }

    public func didConnect(to virtualMachine: VirtualMachine, through connection: SSHConnection) async throws {
        if isMultiOrganization {
            try await startMultiOrganizationRunner(on: virtualMachine, through: connection)
        } else {
            let target = try await selectTarget(slot: virtualMachine.name)
            try await configureRunner(target: target, on: virtualMachine, through: connection)
        }
    }

    // swiftlint:disable:next function_body_length
    private func configureRunner(
        target: GitHubRunnerTarget,
        on virtualMachine: VirtualMachine,
        through connection: SSHConnection,
        directory: String = "actions-runner",
        startRunner: Bool = true
    ) async throws {
        guard let runnerURL = target.url else {
            throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
        }
        let appAccessToken = try await client.getAppAccessToken(target: target)
        let runnerToken = try await client.getRunnerRegistrationToken(
            with: appAccessToken,
            target: target
        )
        let runnerDownloadURL = try await client.getRunnerDownloadURL(
            with: appAccessToken,
            target: target
        )
        let startRunnerScriptFilePath = "~/start-runner.sh"
        try await connection.executeCommand("touch \(startRunnerScriptFilePath)")
        try await connection.executeCommand("""
cat > \(startRunnerScriptFilePath) << EOF
#!/bin/zsh
ACTIONS_RUNNER_ARCHIVE=./actions-runner.tar.gz
ACTIONS_RUNNER_DIRECTORY=~/\(directory)

# Ensure the virtual machine is restarted when a job is done.
set -e pipefail
function onexit {
  sudo shutdown -h now
}
\(startRunner ? "trap onexit EXIT" : "")

# Wait until we can connect to GitHub.
until curl -Is https://github.com &>/dev/null; do :; done

# Download the runner if the runner directory and
# archive does not already exist.
if [ ! -d \\$ACTIONS_RUNNER_DIRECTORY ]; then
  if [ ! -f \\$ACTIONS_RUNNER_ARCHIVE ]; then
    curl -o \\$ACTIONS_RUNNER_ARCHIVE -L "\(runnerDownloadURL)"
    # Unarchive the runner.
    mkdir -p \\$ACTIONS_RUNNER_DIRECTORY
    tar xzf \\$ACTIONS_RUNNER_ARCHIVE --directory \\$ACTIONS_RUNNER_DIRECTORY
  fi
fi

# Holds environment passed to runner.
RUNNER_ENV=""

# Configure pre-run script.
PRE_RUN_SCRIPT_PATH="\\$HOME/.tartelet/pre-run.sh"
if [ -f "\\$PRE_RUN_SCRIPT_PATH" ]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_STARTED=\\${PRE_RUN_SCRIPT_PATH}\n"
fi

# Configure post-run script.
POST_RUN_SCRIPT_PATH="\\$HOME/.tartelet/post-run.sh"
if [ -f "\\$POST_RUN_SCRIPT_PATH" ]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_COMPLETED=\\${POST_RUN_SCRIPT_PATH}\n"
fi

# Create .env file in runner's diectory.
if [ "\\$RUNNER_ENV" != "" ]; then
  echo \\$RUNNER_ENV >> \\$ACTIONS_RUNNER_DIRECTORY/.env
fi

# Configure and run the runner.
cd \\$ACTIONS_RUNNER_DIRECTORY
./config.sh\\\\
  --url "\(runnerURL)"\\\\
  --unattended\\\\
  --ephemeral\\\\
  --replace\\\\
  --labels "\(configuration.runnerLabels)"\\\\
  --name "\(runnerName(for: virtualMachine))"\\\\
  --runnergroup "\(configuration.runnerGroup)"\\\\
  --work "_work"\\\\
  --token "\(runnerToken.rawValue)"\\\\
  \(configuration.runnerDisableUpdates ? "--disableupdate" : "")\\\\
  \(configuration.runnerDisableDefaultLabels ? "--no-default-labels" : "")
\(startRunner ? "./run.sh" : "")
EOF
""")
        try await connection.executeCommand("chmod +x \(startRunnerScriptFilePath)")
        try Task.checkCancellation()
        let command = startRunner
            ? "open -a Terminal \(startRunnerScriptFilePath)"
            : "/bin/zsh -l \(startRunnerScriptFilePath)"
        try await connection.executeCommand(command)
    }
    private func startMultiOrganizationRunner(
        on virtualMachine: VirtualMachine, through connection: SSHConnection
    ) async throws {
        let organizations = GitHubOrganizationNames.parse(credentialsStore.organizationName ?? "")
        guard let first = organizations.first else {
            throw GitHubActionsRunnerSSHConnectionHandlerError.organizationNameUnavailable
        }
        let token = try await client.getAppAccessToken(target: .organization(first))
        let download = try await client.getRunnerDownloadURL(with: token, target: .organization(first))
        let root = ".tartelet/runners-" + UUID().uuidString
        try await connection.executeCommand("""
set -e
if [ ! -d "$HOME/actions-runner" ]; then
  curl -fL -o "$HOME/actions-runner.tar.gz" "\(download)"
  mkdir -p "$HOME/actions-runner"
  tar xzf "$HOME/actions-runner.tar.gz" --directory "$HOME/actions-runner"
fi
mkdir -p "$HOME/\(root)"
""")
        for (index, organization) in organizations.enumerated() {
            let directory = "\(root)/org-\(index)"
            try await connection.executeCommand("cp -R \"$HOME/actions-runner\" \"$HOME/\(directory)\"")
            try await configureRunner(
                target: .organization(organization), on: virtualMachine, through: connection,
                directory: directory, startRunner: false
            )
            logger.info("Registered offline runner \(virtualMachine.name) in \(organization)")
        }
        let target = try await selectTarget(slot: virtualMachine.name)
        guard case let .organization(selected) = target,
              let index = organizations.firstIndex(of: selected) else {
            throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
        }
        // Only the selected organization's credentials may remain when a job starts.
        for other in organizations.indices where other != index {
            try await connection.executeCommand("rm -rf \"$HOME/\(root)/org-\(other)\"")
        }
        try await connection.executeCommand("""
cat > "$HOME/start-runner.sh" <<'EOF'
#!/bin/zsh
set -e
trap 'sudo shutdown -h now' EXIT
cd "$HOME/\(root)/org-\(index)"
/bin/bash ./env.sh
./run.sh
EOF
chmod +x "$HOME/start-runner.sh"
""")
        let accessToken = try await client.getAppAccessToken(target: target)
        try Task.checkCancellation()
        try await connection.executeCommand("open -a Terminal ~/start-runner.sh")
        try await waitForJob(on: virtualMachine, through: connection, target: target, token: accessToken)
    }

    private func runnerName(for virtualMachine: VirtualMachine) -> String {
        let configuredRunnerName = configuration.runnerName

        // If no custom runner name is configured, use the VM name as-is
        if configuredRunnerName.isEmpty {
            return virtualMachine.name
        }

        // Extract the index suffix from VM names like "baseVM-1", "baseVM-2"
        let vmName = virtualMachine.name
        if let lastDashIndex = vmName.lastIndex(of: "-") {
            let indexString = String(vmName[vmName.index(after: lastDashIndex)...])
            if !indexString.isEmpty, Int(indexString) != nil {
                return "\(configuredRunnerName) \(indexString)"
            }
        }
        // Fallback to just the runner name if we can't extract an index
        return configuredRunnerName
    }
}

extension GitHubActionsRunnerSSHConnectionHandler {
    private var isMultiOrganization: Bool {
        configuration.runnerScope == .organization
            && GitHubOrganizationNames.parse(credentialsStore.organizationName ?? "").count > 1
    }

    private func selectTarget(slot: String) async throws -> GitHubRunnerTarget {
        switch configuration.runnerScope {
        case .organization:
            let organizations = GitHubOrganizationNames.parse(credentialsStore.organizationName ?? "")
            guard let first = organizations.first else {
                throw GitHubActionsRunnerSSHConnectionHandlerError.organizationNameUnavailable
            }
            guard organizations.count > 1 else { return .organization(first) }
            guard let scheduler else {
                preconditionFailure("Multiple organizations require a shared scheduler")
            }
            var labels = Set(configuration.runnerLabels.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
            if !configuration.runnerDisableDefaultLabels {
                labels.formUnion(["self-hosted", "macos", "arm64"])
            }
            while true {
                try Task.checkCancellation()
                if let organization = try await scheduler.nextOrganization(
                    slot: slot, organizations: organizations, labels: labels
                ) {
                    logger.info("Assigned \(slot) to GitHub organization \(organization)")
                    return .organization(organization)
                }
                try await Task.sleep(for: .seconds(5))
            }
        case .repo:
            guard let owner = credentialsStore.ownerName, let name = credentialsStore.repositoryName else {
                throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
            }
            return .repository(owner: owner, name: name)
        }
    }

    func waitForJob(
        on virtualMachine: VirtualMachine,
        through connection: SSHConnection,
        target: GitHubRunnerTarget,
        token: GitHubAppAccessToken,
        timeout: Duration = .seconds(300),
        pollInterval: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var accessToken = token
        var refreshTokenAt = ContinuousClock.now.advanced(by: .seconds(1_800))
        while true {
            try Task.checkCancellation()
            let state: Result<RunnerWaitState, Error>
            do {
                if ContinuousClock.now >= refreshTokenAt {
                    accessToken = try await client.getAppAccessToken(target: target)
                    refreshTokenAt = ContinuousClock.now.advanced(by: .seconds(1_800))
                }
                state = .success(try await runnerWaitState(
                    name: runnerName(for: virtualMachine), target: target, token: accessToken,
                    hasTimedOut: ContinuousClock.now >= deadline
                ))
            } catch {
                state = .failure(error)
            }
            switch state {
            case .success(.running):
                await scheduler?.didStartJob(slot: virtualMachine.name)
                return
            case .success(.retired):
                logger.info("Runner in \(virtualMachine.name) timed out waiting for a job")
                try await connection.executeCommand("sudo shutdown -h now")
                throw GitHubActionsRunnerSSHConnectionHandlerError.runnerWaitTimedOut
            case .success(.waiting):
                break
            case let .failure(error):
                try Task.checkCancellation()
                // An unavailable API cannot prove that the runner is idle. Keep the VM alive.
                logger.error(
                    "Could not check or retire runner in \(virtualMachine.name): \(error.localizedDescription)"
                )
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private enum RunnerWaitState {
        case waiting
        case running
        case retired
    }

    private func runnerWaitState(
        name: String, target: GitHubRunnerTarget, token: GitHubAppAccessToken, hasTimedOut: Bool
    ) async throws -> RunnerWaitState {
        let runner = try await client.getRunner(with: token, target: target, name: name)
        if runner?.busy == true { return .running }
        guard hasTimedOut else { return .waiting }
        if let runner {
            do {
                try await client.removeRunner(with: token, target: target, id: runner.id)
            } catch {
                // A job may have been assigned between checking busy and removing the runner.
                let current = try await client.getRunner(with: token, target: target, name: name)
                if current?.busy == true { return .running }
                throw error
            }
        }
        return .retired
    }
}
