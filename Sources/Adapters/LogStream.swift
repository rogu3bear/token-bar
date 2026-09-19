import Foundation
import CoreServices

/// Filesystem notifications wake the tail reader; no polling is used for active append traffic.
final class LogStream {
    let home: URL
    let grokHome: URL?
    let claudeHome: URL?
    let openCodeHome: URL?
    let onFiles: (Set<URL>) -> Void
    let onAccount: () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "local.codex-token-bar.files", qos: .userInitiated, autoreleaseFrequency: .workItem)
    init(home: URL, grokHome: URL? = nil, claudeHome: URL? = nil, openCodeHome: URL? = nil, onFiles: @escaping (Set<URL>) -> Void, onAccount: @escaping () -> Void) {
        self.home = home; self.grokHome = grokHome; self.claudeHome = claudeHome; self.openCodeHome = openCodeHome; self.onFiles = onFiles; self.onAccount = onAccount
    }
    func route(paths: [String], flags: [FSEventStreamEventFlags]) -> (files: Set<URL>, account: Bool) {
        var files = Set<URL>()
        var account = false
        let roots = [home, grokHome, claudeHome, openCodeHome].compactMap { $0 }
        for (index, rawPath) in paths.enumerated() {
            let observedPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
            // FSEvents reports physical paths. Return the configured spelling so
            // scanner scope and persisted cursor identities remain consistent.
            var path = observedPath
            for root in roots {
                let physical = root.resolvingSymlinksInPath().path
                if observedPath == physical || observedPath.hasPrefix(physical + "/") {
                    path = root.path + observedPath.dropFirst(physical.count)
                    break
                }
            }
            let dropped = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
            if dropped {
                for root in roots where path == root.path || path.hasPrefix(root.path + "/") { files.insert(root) }
            }
            if path.hasPrefix(CodexCatalog.database(in: self.home).path) { files.insert(URL(fileURLWithPath: path)) }
            if let openCode = self.openCodeHome,
               ["opencode.db", "opencode.db-wal", "opencode.db-shm"].contains(URL(fileURLWithPath: path).lastPathComponent),
               path.hasPrefix(openCode.path + "/") { files.insert(URL(fileURLWithPath: path)) }
            if path == self.home.appendingPathComponent("auth.json").path { account = true }
            if path.hasSuffix(".jsonl") && (path.hasPrefix(self.home.appendingPathComponent("sessions").path + "/") || path.hasPrefix(self.home.appendingPathComponent("archived_sessions").path + "/")) {
                files.insert(URL(fileURLWithPath: path))
            }
            if let claude = self.claudeHome, path.hasPrefix(claude.appendingPathComponent("projects").path + "/"), path.hasSuffix(".jsonl") {
                files.insert(URL(fileURLWithPath: path))
            }
            if let grok = self.grokHome, path.hasPrefix(grok.path + "/"),
               path.hasSuffix("/usage.json") || path.hasSuffix("/signals.json") || path.hasSuffix("/summary.json") || path.hasSuffix("/meta.json")
                || path == grok.appendingPathComponent("active_sessions.json").path {
                files.insert(URL(fileURLWithPath: path))
            }
        }
        return (files, account)
    }
    func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<LogStream>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            let (changed, changedAccount) = owner.route(paths: Array(paths.prefix(count)), flags: Array(UnsafeBufferPointer(start: flags, count: count)))
            DispatchQueue.main.async {
                if !changed.isEmpty { owner.onFiles(changed) }
                if changedAccount { owner.onAccount() }
            }
        }
        var roots = [home.path]
        if let grokHome { roots.append(grokHome.path) }
        if let claudeHome { roots.append(claudeHome.path) }
        if let openCodeHome { roots.append(openCodeHome.path) }
        stream = FSEventStreamCreate(nil, callback, &context, roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream { FSEventStreamSetDispatchQueue(stream, queue); FSEventStreamStart(stream) }
    }
    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    deinit { stop() }
}
