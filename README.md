![Hero artwork](artwork.jpg)

## 👋 Welcome to Tartelet - a macOS app that launches self-hosted GitHub Actions runners in virtual machines using [Tart](https://github.com/cirruslabs/tart).

Tartelet makes it a breeze to manage up to two GitHub Actions runners in ephemeral virtual machines on a single host machine. The benefits are that runners can run in parallel and each job runs in an isolated environment that is recreated after each GitHub Actions job has finished.

- [🚀 Getting Started](https://github.com/shapehq/tartelet#-getting-started)
- [👨‍🔧 How does it work?](https://github.com/shapehq/tartelet#-how-does-it-work)
- [🏎 How is the performance?](https://github.com/shapehq/tartelet#-how-is-the-performance)
- [👩‍💻 How can I contribute?](https://github.com/shapehq/tartelet#-how-can-i-contribute)
- [🤨 Why is it named Tartelet?](https://github.com/shapehq/tartelet#-why-is-it-named-tartelet)
- [🙏 Acknowledgements](https://github.com/shapehq/tartelet#-acknowledgements)

## 🚀 Getting Started

Please refer to the following articles in [the wiki](https://github.com/shapehq/tartelet/wiki) to get started with Tartelet.

- [Installing Tartelet](https://github.com/shapehq/tartelet/wiki/Installing-Tartelet)
- [Configuring Tartelet](https://github.com/shapehq/tartelet/wiki/Configuring-Tartelet)
- [Starting the Virtual Machines](https://github.com/shapehq/tartelet/wiki/Starting-the-Virtual-Machines)

## 👨‍🔧 How does it work?

![Screenshot of Tartelet running two virtual machines](screenshot.jpg)

Tartelet uses Tart for managing the virtual machines and Tart which in turn uses Apple's [Apple's Virtualization framework](https://developer.apple.com/documentation/virtualization). The lifecycle of a GitHub Actions runner managed by Tartelet is as follows:

1. Tartelet uses Tart to clone a virtual machine.
2. The virtual machine is booted.
3. After the machine is booted, a setup script is being run. The script downloads the newest version of [GitHub's runner application](https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners) and registers the runner on the GitHub organization.
4. The runner listens for a job and executes it.
5. After executing the job, the runner automatically removes itself from the GitHub organization.
6. The virtual machine is shutdown.
7. Tartelet uses Tart to delete the virtual machine.

After the last step the process starts over.

### Sharing virtual machines across organizations

Enter a comma-separated list such as `org-a,org-b` in **GitHub → Organizations**.
Install the same GitHub App in each organization, granting organization **Self-hosted
runners: Read and write** and repository **Actions: Read-only** permissions. Give the
App access to every repository whose jobs should use these runners. Runner labels
and group settings apply to all configured organizations; ensure the group exists
and permits the intended repositories in each organization.

With multiple organizations, each VM registers an ephemeral runner in every
organization at startup. These runners appear **Offline** while waiting; only the
runner chosen to execute a job is started. Tartelet checks GitHub every 30 seconds
and chooses organizations with waiting jobs in round-robin order. A
shared scheduler reserves capacity before registering each ephemeral runner, so
two VMs can share an organization when it has enough queued jobs. GitHub chooses
the individual job; global FIFO ordering is not guaranteed.

Before starting a job, the VM deletes the other organizations' local runner
credentials. Their GitHub entries stay offline and are replaced when the next VM
starts. Runner names remain stable for each VM slot.

After a job finishes, the VM is deleted and recreated as usual. A runner that has
not received a job after five minutes is removed and its VM is recreated. This
also handles jobs canceled or taken by another runner after the scheduling check.
Single-organization and repository configurations keep their existing behavior.

Polling lists repositories, active workflow runs, and jobs using the App's API
quota. Large installations may need a longer polling interval or a webhook-based
scheduler. Authentication, permission, and API errors are logged and propagated;
they are not treated as an empty job queue. After a runner has been launched,
monitoring errors are logged and retried while keeping the VM alive, because a
failed API request cannot establish whether a job is running.

## 🏎 How is the performance?

The performance depends on the hardware that the app is running on. When testing on a Mac mini M1 from 2020 with 16 GB memory, we found that our jobs run 3 - 4 times faster than on GitHub's runners.

We found that our jobs run about 12% slower when running two virtual machines in parallel compared to running a single virtual machine. We find this performance cost negligible as running two virtual machines significantly increases our throughput at a low monetary cost.

This means that Tartelet can run two virtual machines at once. This the maximum number of virtual machines that Apple’s Virtualization framework allows us to run at once.

After a job has finished, the virtual machine that ran the job is shut down and destroyed, and a new virtual machine is created and booted. This process takes about 25 - 30 seconds. However, that overhead is insignificant in most cases as Tartelet creates a new virtual machine after each job has finished. This means that a new virtual machine and its GitHub Actions runner are ready to process the next job. Unless there are more jobs queued on GitHub than the number of available virtual machines, the overhead of creating and booting a virtual machine becomes negligible.

These numbers were last updated in January/February 2023.

## 👩‍💻 How can I contribute?

Pull requests with bugfixes and new features are much appreciated. We are happy to review PRs and merge them once they are ready, as long as they contain changes that fit within the vision of Tartelet.

Clone the repository to get started working on the project.

```bash
git clone git@github.com:shapehq/tartelet.git
```

### Generating a Project File with XcodeGen

After cloning the repository you will notice that the project does not contain a .xcodeproj file. This should be generated using [XcodeGen](https://github.com/yonaskolb/XcodeGen). Install XcodeGen using [Homebrew](https://brew.sh) by running the following command in your terminal.

```bash
brew install xcodegen
```

After installing XcodeGen the project file can be generated by running the following command.

```bash
xcodegen generate
```

### Generating Resource Constants with SwiftGen

We use [SwiftGen](https://github.com/SwiftGen/SwiftGen) to generate constants for images, colors, and localizations. Install SwiftGen using [Homebrew](https://brew.sh) by running the following command in your terminal.

```bash
brew install swiftgen
```

Constants for images, colors, and localizations are then generated by running the following command in your terminal.

```bash
swiftgen
```

The `swiftgen.yml` file at the root of the repository describes how constants are generated.

### Building and releasing

Push a version tag on the commit you want to distribute:

```bash
git tag v0.13.0
git push origin v0.13.0
```

The `Release` GitHub Actions workflow runs the GitHub and VM package tests,
builds the Apple Silicon app in Release configuration, and publishes
`Tartelet-v0.13.0-arm64.dmg` and its SHA-256 checksum to GitHub Releases.
Tags such as `v0.13.0-beta.1` create prereleases. The app's version comes from
the numeric part of the tag. The workflow must exist in the tagged commit;
it can release commits on `multi-runner` without merging into `main`.

The workflow uses Developer ID Application signing and App Store Connect team API
credentials, matching Mogura's release setup. Set these repository secrets:

- `MACOS_CERTIFICATE_P12_BASE64`: Base64-encoded Developer ID Application certificate
  and its private key, exported as a password-protected `.p12`.
- `MACOS_CERTIFICATE_PASSWORD`: Password used to export that `.p12`.
- `MACOS_PROVISIONING_PROFILE_BASE64`: Base64-encoded **Developer ID** provisioning
  profile authorizing this certificate, `com.9wick.Tartelet`, and its Keychain
  access group. Create/download it in Apple Developer → Certificates, Identifiers
  & Profiles → Profiles. This is also embedded by the upstream release.
- `APPLE_API_KEY_P8_BASE64`: Base64-encoded App Store Connect team API private key.
- `APPLE_API_KEY_ID`: Key ID for that API key.
- `APPLE_API_ISSUER_ID`: Issuer ID for that API key (not the Apple Team ID).

The same original credentials used for Mogura can be registered here. GitHub
cannot return existing secret values, so they cannot be copied from another
repository through the API. Do not commit certificates, API keys, or passwords.

The upstream Keychain storage implementation is retained. The release signs with
the entitlements from `main`, expands the signing prefix using the provisioning
profile, and embeds that profile. No upstream team's profile is reused.

The workflow imports credentials into a temporary Keychain under `.tmp/` and
removes it after the job. It signs the app with Hardened Runtime and a secure
timestamp, notarizes and staples the app, then creates, signs, notarizes and
staples the DMG. Gatekeeper must accept both the app and DMG, including the app
mounted from the final DMG, before a release is published. Checksums are written
after stapling. Missing credentials or failed notarization stop the release;
there is no ad-hoc signing fallback.

The existing `v0.12.0-multi.0` release used ad-hoc signing and was not notarized.
New notarized builds should use the next version tag rather than replacing a
published release's assets. The app uses its default Keychain access rather than
an access group tied to the upstream team.

The workflow uploads assets to a draft before publishing. If a run fails after
creating the draft, delete that draft before rerunning; existing releases are
not overwritten. A release requires `vMAJOR.MINOR.PATCH`, optionally followed by
a prerelease suffix, such as `-beta.1`.

For a local build, install Xcode and XcodeGen, generate the project, and select
your own development team in Xcode. Local packaging also requires `jq` and
Xcode's `notarytool` and `stapler`. To package an existing Apple Silicon build,
export `TARTELET_SIGN_IDENTITY`
(the Developer ID certificate hash), `TARTELET_SIGNING_KEYCHAIN` (the Keychain
path) and `TARTELET_NOTARY_PROFILE` (the profile stored in that Keychain), then run:

```bash
bash scripts/package-dmg.sh /path/to/Tartelet.app v0.13.0 dist
```

### Linting the Codebase with SwiftLint

We use [SwiftLint](https://github.com/realm/SwiftLint) to ensure uniformity in the code. Install SwiftLint using [Homebrew](https://brew.sh) by running the following command in your terminal.

```bash
brew install swiftlint
```

## 🤨 Why is it named Tartelet?

The app is named Tartelet because it builds upon [Tart](https://tart.run), a source-available CLI for managing macOS virtual machines. Tartelet makes it easy to run multiple virtual machines using Tart. The Danish word for "easy" is "let". "Tart" + "e" + "let" = "Tartelet" and [a "tartelet" is a traditional Danish food.](https://www.valdemarsro.dk/tarteletter-hoens-asparges/)

<img src="Tartelet/Assets.xcassets/AppIcon.appiconset/Artboard_512x512.png?raw=true" width="192" />

## 🙏 Acknowledgements

- [Tart](https://github.com/cirruslabs/tart) does all the heavy-lifting of creating, cloning, and running virtual machines.
- Tartelet is heavily inspired by [Cilicon](https://github.com/traderepublic/Cilicon).

---

Tartelet is built with ❤️ by [Shape](https://shape.dk) in Denmark. Oh, and [we are hiring](https://careers.shape.dk) 🤗

### Shared cache lease recovery

Before starting a VM, Tartelet removes a leftover
`cache/github-actions-cache-server/writer.lock` only when no local VM is running
in the configured Tart home and no cooperating Tartelet instance has reserved a
VM startup or run. A host file lock protects this check through the VM's lifetime
and is released by the OS if Tartelet exits. Cache snapshots and `CURRENT` are
left untouched; uncommitted data from a terminated VM is not recovered.

All instances sharing this cache must use this recovery protocol. Do not launch
VMs manually with the same shared cache while Tartelet is starting a VM. A running
VM found by `tart list` preserves the lease; listing or recovery errors fail the
startup instead of assuming that the cache is unused.
