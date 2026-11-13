import Darwin
import Foundation

/// Keeps a host-side reservation until `tart run` exits, including startup and shutdown.
final class SharedCacheAccess {
    private let descriptor: Int32
    private let cacheFolder: URL
    private(set) var canRecover = false

    init(cacheFolder: URL) throws {
        self.cacheFolder = cacheFolder
        let lockPath = cacheFolder.appendingPathComponent(".tartelet-access.lock").path
        descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            canRecover = true
        } else {
            let code = errno
            guard code == EWOULDBLOCK, flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                let failure = code == EWOULDBLOCK ? errno : code
                close(descriptor)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
            canRecover = false
        }
    }

    deinit {
        close(descriptor)
    }

    /// Recovery requires both an exclusive reservation and no running VM in this Tart home.
    /// The shared reservation then prevents recovery by another Tartelet during this VM's lifetime.
    func prepare(hasRunningVirtualMachines: Bool) throws {
        if canRecover && !hasRunningVirtualMachines {
            let lease = cacheFolder.appendingPathComponent("github-actions-cache-server/writer.lock")
            if FileManager.default.fileExists(atPath: lease.path) {
                try FileManager.default.removeItem(at: lease)
            }
        }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        canRecover = false
    }
}
