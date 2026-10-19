import Foundation
import Darwin

/// One derived reconstruction workspace per ledger, including after interruption.
/// Old UUID workspaces are never discovered, adopted or removed here.
final class CostRecoveryWorkspace {
    let root: URL
    private var descriptor: Int32 = -1
    private var preserve = false
    private var binding = ""
    private var rootDevice: dev_t = 0
    private var rootInode: ino_t = 0
    private var lockPath = ""
    init(stateURL: URL) throws {
        guard let physical = realpath(stateURL.deletingLastPathComponent().path, nil) else {
            throw RequestArchive.failure("Cost recovery's ledger directory is unavailable")
        }
        defer { free(physical) }
        let parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        root = parent.appendingPathComponent("cost-recovery-workspace", isDirectory: true)
        let owner = root.appendingPathComponent("owner")
        binding = "Token Bar derived cost workspace v1\n" + EventIdentity.hash(stateURL.resolvingSymlinksInPath().path) + "\n"
        let lockURL = parent.appendingPathComponent("cost-recovery-owner.lock")
        lockPath = lockURL.path
        descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RequestArchive.failure("Cost recovery lock is unavailable; existing files were preserved") }
        var ready = false
        defer { if !ready { close(descriptor); descriptor = -1 } }
        var held = stat()
        guard fstat(descriptor, &held) == 0, Self.privateRegular(held) else {
            throw RequestArchive.failure("Cost recovery lock is not a private single-link file; it was preserved")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw RequestArchive.failure("Cost recovery is already using this ledger's workspace")
        }
        var named = stat()
        guard lstat(lockURL.path, &named) == 0, Self.privateRegular(named), named.st_ino == held.st_ino, named.st_dev == held.st_dev else {
            throw RequestArchive.failure("Cost recovery lock changed; existing files were preserved")
        }
        let exists = try checked(root, directory: true)
        if exists {
            guard try checked(owner), try String(contentsOf: owner, encoding: .utf8) == binding else {
                throw RequestArchive.failure("Cost recovery workspace is not owned by this ledger; it was preserved")
            }
        } else {
            guard mkdir(root.path, 0o700) == 0 else { throw RequestArchive.failure("Cost recovery workspace could not be claimed") }
            try Data(binding.utf8).write(to: owner, options: .atomic)
            try PrivateFile.protect(owner)
        }
        var claimed = stat()
        guard lstat(root.path, &claimed) == 0 else { throw RequestArchive.failure("Cost recovery workspace changed during claim") }
        rootDevice = claimed.st_dev; rootInode = claimed.st_ino
        ready = true
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
    private static func privateRegular(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && status.st_nlink == 1 &&
            status.st_uid == geteuid() && status.st_mode & 0o077 == 0
    }
    @discardableResult private func checked(_ url: URL, directory: Bool = false) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return false }
            throw RequestArchive.failure("Cost recovery workspace could not be inspected; it was preserved")
        }
        let valid = directory
            ? status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && status.st_uid == geteuid() && status.st_mode & 0o077 == 0
            : Self.privateRegular(status)
        guard valid else { throw RequestArchive.failure("Cost recovery refuses an aliased or non-private derived path; it was preserved") }
        return true
    }
    private func requireOwnership() throws {
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, Self.privateRegular(held),
              lstat(lockPath, &named) == 0, Self.privateRegular(named),
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
            throw RequestArchive.failure("Cost recovery lock identity changed; workspace was preserved")
        }
        let owner = root.appendingPathComponent("owner")
        guard try checked(root, directory: true), try checked(owner) else {
            throw RequestArchive.failure("Cost recovery ownership evidence is missing; workspace was preserved")
        }
        var current = stat()
        guard lstat(root.path, &current) == 0, current.st_dev == rootDevice, current.st_ino == rootInode,
              try String(contentsOf: owner, encoding: .utf8) == binding else {
            throw RequestArchive.failure("Cost recovery ownership changed; workspace was preserved")
        }
    }
    /// Reset only this action-owned derived state, never a user's admitted store.
    func prepare(providerOnly: Bool = false) throws -> URL {
        do { return try reset(providerOnly: providerOnly) }
        catch { preserve = true; throw error }
    }
    private func reset(providerOnly: Bool) throws -> URL {
        try requireOwnership()
        let directory = root.appendingPathComponent(providerOnly ? "providers" : "main", isDirectory: true)
        if try checked(directory, directory: true) == false {
            guard mkdir(directory.path, 0o700) == 0 else { throw RequestArchive.failure("Cost recovery derived directory could not be created") }
        }
        let ledger = directory.appendingPathComponent("ledger.json")
        for name in ["ledger.json", "ledger.checkpoint.json", "ledger.events.sqlite", "ledger.requests.sqlite"] {
            try checked(directory.appendingPathComponent(name))
            if name.hasSuffix(".sqlite") {
                for suffix in ["-journal", "-wal", "-shm"] { try checked(directory.appendingPathComponent(name + suffix)) }
            }
        }
        try EventIndex(url: ledger.deletingPathExtension().appendingPathExtension("events.sqlite"), required: false, refuseAliases: true).resetReconstruction()
        try RequestArchive(url: ledger.deletingPathExtension().appendingPathExtension("requests.sqlite"), refuseAliases: true).resetReconstruction()
        var baseline = Ledger(); baseline.checkpointID = UUID()
        try PrivateCache.write(baseline, to: ledger)
        try PrivateCache.write(LedgerMetadataCheckpoint(baseline: baseline.checkpointID!, metadata: baseline),
                               to: UsageScanner.metadataURL(for: ledger))
        return ledger
    }
    /// Preserve the existing successful/throwing-return cleanup, while holding custody.
    func finish() {
        guard !preserve else { return }
        do { try requireOwnership(); try FileManager.default.removeItem(at: root) }
        catch { preserve = true }
    }
}
