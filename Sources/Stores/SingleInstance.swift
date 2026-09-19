import Foundation
import AppKit

/// Guarantees one writer per ledger.
///
/// Two copies of this app writing one ledger is the failure that corrupts
/// history, and it does not require a careless user: fifteen bundles carrying
/// this bundle identifier can exist on a working machine at once, between the
/// installed copy, build output and archived exports. Bundle-identifier checks
/// alone do not cover that, because a stale copy is a different file at a
/// different path claiming the same identity.
///
/// So the guarantee is anchored on the thing that must not be shared: the
/// ledger itself. Whoever holds an exclusive lock on the lock file beside it is
/// the writer. Anyone else refuses to write, and says who holds it.
final class LedgerLock {
    private var descriptor: Int32 = -1
    private(set) var path: String = ""

    /// The process holding the lock, when someone else has it.
    struct Holder {
        var pid: pid_t
        var bundlePath: String
        var isRunning: Bool
    }

    /// Take the lock, or report who holds it. Never blocks.
    @discardableResult
    func acquire(besideLedger ledger: URL) -> Bool {
        guard descriptor < 0 else { return true }
        let lock = ledger.deletingPathExtension().appendingPathExtension("lock")
        path = lock.path
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let handle = open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard handle >= 0 else { return false }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            close(handle)
            return false
        }
        descriptor = handle
        // Record who we are, so a second copy can name the holder rather than
        // showing an unexplained refusal.
        ftruncate(handle, 0)
        let identity = "\(ProcessInfo.processInfo.processIdentifier)\n\(Bundle.main.bundlePath)\n"
        _ = identity.withCString { write(handle, $0, strlen($0)) }
        fsync(handle)
        return true
    }

    /// Who currently holds the lock, read from the lock file.
    func holder() -> Holder? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let pid = lines.first.flatMap({ pid_t($0) }) else { return nil }
        let bundle = lines.count > 1 ? String(lines[1]) : ""
        // Signal 0 tests for existence without disturbing the process.
        return Holder(pid: pid, bundlePath: bundle, isRunning: kill(pid, 0) == 0 || errno == EPERM)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// What to tell someone whose second copy refused to start.
enum DuplicateInstance {
    static func message(holder: LedgerLock.Holder?, thisBundle: String = Bundle.main.bundlePath) -> String {
        guard let holder else {
            return "Another copy of Token Bar is already using your usage history. This copy will not start, so the two cannot disagree about your totals."
        }
        let same = holder.bundlePath == thisBundle
        if same {
            return "Token Bar is already running. Use the existing menu-bar item rather than a second copy."
        }
        return """
        Another copy of Token Bar is already using your usage history:

        \(holder.bundlePath)

        This copy is at:

        \(thisBundle)

        Only one copy may write your history, so this one will not start. Keep the copy in your Applications folder and delete the other to avoid confusion.
        """
    }
}

/// Finds every copy of this app on the machine.
///
/// The installer deliberately does not delete copies outside `/Applications`,
/// because removing a person's files is not an installer's business. Reporting
/// them is, so a stale copy can be found and removed deliberately.
enum DuplicateScan {
    struct Copy {
        var path: String
        var version: String?
        var build: String?
        var isInstalled: Bool { path == DuplicateScan.installedPath }
    }

    static let identifier = "local.star.CodexTokenBar"
    static let installedPath = "/Applications/Token Bar.app"

    /// Ask Spotlight for bundles carrying this identifier.
    static func find() -> [Copy] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemCFBundleIdentifier == \'\(identifier)\'"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { describe(String($0)) }
            .sorted { ($0.isInstalled ? 0 : 1, $0.path) < ($1.isInstalled ? 0 : 1, $1.path) }
    }

    static func describe(_ path: String) -> Copy {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return Copy(path: path, version: nil, build: nil)
        }
        return Copy(path: path,
                    version: object["CFBundleShortVersionString"] as? String,
                    build: object["CFBundleVersion"] as? String)
    }

    /// A report a person can act on.
    static func report(_ copies: [Copy]) -> String {
        guard !copies.isEmpty else { return "No copies of Token Bar were found." }
        var lines = ["\(copies.count) copy or copies of Token Bar found.", ""]
        for copy in copies {
            let version = [copy.version, copy.build.map { "build \($0)" }].compactMap { $0 }.joined(separator: ", ")
            lines.append("  \(copy.isInstalled ? "[installed]" : "[other]    ") \(copy.path)")
            if !version.isEmpty { lines.append("              \(version)") }
        }
        if copies.contains(where: { !$0.isInstalled }) {
            lines.append("")
            lines.append("Only one copy can write your usage history; the others are refused at launch.")
            lines.append("Copies outside /Applications are left alone by the installer. Remove any you")
            lines.append("no longer need, and keep the one in /Applications.")
        }
        return lines.joined(separator: "\n")
    }
}
