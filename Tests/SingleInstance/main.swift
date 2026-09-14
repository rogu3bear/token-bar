import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-lock-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let ledger = root.appendingPathComponent("CodexTokenBar/ledger.json")

// One writer ----------------------------------------------------------------
let first = LedgerLock()
check(first.acquire(besideLedger: ledger), "the first copy must take the lock")
check(FileManager.default.fileExists(atPath: first.path), "the lock file must exist beside the ledger")
check(first.path.hasSuffix(".lock"), "the lock must sit beside the ledger, got \(first.path)")
print("PASS: the first copy takes the ledger lock")

// A second copy in the same process is idempotent, not a second writer.
check(first.acquire(besideLedger: ledger), "re-acquiring an already-held lock must succeed")
print("PASS: re-acquiring a held lock does not create a second writer")

// The holder is identifiable, so a refusal can name it.
let holder = first.holder()
check(holder != nil, "the lock must record who holds it")
check(holder?.pid == ProcessInfo.processInfo.processIdentifier, "the recorded pid must be this process")
check(holder?.isRunning == true, "a live holder must be reported as running")
print("PASS: the lock names the process holding it")

// A second process is refused ----------------------------------------------
// flock is per open file description, so a genuinely separate process is the
// only honest test. A child asks for the same lock while this one holds it.
let probe = """
import Foundation
let lock = LedgerLock()
let taken = lock.acquire(besideLedger: URL(fileURLWithPath: CommandLine.arguments[1]))
print(taken ? "ACQUIRED" : "REFUSED")
"""
let probeDir = root.appendingPathComponent("probe")
try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
try probe.write(to: probeDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

func runProbe() -> String {
    let sources = CommandLine.arguments.dropFirst().first ?? ""
    let binary = probeDir.appendingPathComponent("probe")
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compile.arguments = ["swiftc", "-swift-version", "5", sources,
                         probeDir.appendingPathComponent("main.swift").path, "-o", binary.path]
    let quiet = Pipe(); compile.standardError = quiet; compile.standardOutput = quiet
    try? compile.run(); compile.waitUntilExit()
    guard compile.terminationStatus == 0 else { return "COMPILE_FAILED" }
    let run = Process()
    run.executableURL = binary
    run.arguments = [ledger.path]
    let output = Pipe(); run.standardOutput = output
    try? run.run(); run.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let result = runProbe()
check(result != "COMPILE_FAILED", "the probe must compile; pass the SingleInstance source path as argument 1")
check(result == "REFUSED", "a separate process must be refused while the lock is held, got \(result)")
print("PASS: a second process is refused the ledger lock while another holds it")

// Releasing hands the lock on ----------------------------------------------
first.release()
check(runProbe() == "ACQUIRED", "the lock must be available once released")
print("PASS: releasing the lock lets the next copy take it")

// Messaging -----------------------------------------------------------------
let elsewhere = LedgerLock.Holder(pid: 4242, bundlePath: "/Users/x/Downloads/Token Bar.app", isRunning: true)
let message = DuplicateInstance.message(holder: elsewhere, thisBundle: "/Applications/Token Bar.app")
check(message.contains("/Users/x/Downloads/Token Bar.app"), "the refusal must name the copy holding the history")
check(message.contains("/Applications/Token Bar.app"), "the refusal must name the copy being refused")
check(message.lowercased().contains("only one copy"), "the refusal must say why it happened")
print("PASS: a refusal names both copies and explains itself")

let same = DuplicateInstance.message(holder: LedgerLock.Holder(pid: 1, bundlePath: "/Applications/Token Bar.app", isRunning: true),
                                     thisBundle: "/Applications/Token Bar.app")
check(same.contains("already running"), "relaunching the same copy must read as already running")
check(!same.contains("delete"), "relaunching one copy must not suggest deleting anything")
print("PASS: relaunching the same copy is explained without suggesting a deletion")

let unknown = DuplicateInstance.message(holder: nil)
check(!unknown.isEmpty && unknown.lowercased().contains("history"), "an unknown holder still gets an explanation")
print("PASS: an unreadable lock still produces an explanation rather than a bare failure")

print("PASS: single-instance suite complete")
