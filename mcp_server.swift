import Foundation

/// LaunchAgent entry for HTTP MCP. Stays a signed binary inside the .app so
/// Sequoia Login Items name this product, not Homebrew "node".
/// Child is node mcp.mjs --http; this process keeps the name/identity.

func repoRoot(from executable: String) -> URL {
    let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func findNode() -> String? {
    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let candidates =
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        + envPath.split(separator: ":").map { String($0) + "/node" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

let root = repoRoot(from: CommandLine.arguments[0])
let script = root.appendingPathComponent("mcp.mjs").path
guard FileManager.default.isReadableFile(atPath: script) else {
    fputs("computer-use-mcp: mcp.mjs missing at \(script)\n", stderr)
    exit(1)
}
guard let node = findNode() else {
    fputs("computer-use-mcp: node not found\n", stderr)
    exit(1)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: node)
proc.arguments = [script, "--http"]
proc.currentDirectoryURL = root
var env = ProcessInfo.processInfo.environment
env["PYTHONUNBUFFERED"] = "1"
let path = env["PATH"] ?? ""
if !path.contains("/opt/homebrew/bin") {
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}
proc.environment = env
proc.terminationHandler = { p in
    exit(p.terminationStatus)
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let onTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let onInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
onTerm.setEventHandler { proc.terminate() }
onInt.setEventHandler { proc.terminate() }
onTerm.resume()
onInt.resume()

fputs(
    "computer-use-mcp: \(node) \(script) --http\n",
    stderr
)
do {
    try proc.run()
} catch {
    fputs("computer-use-mcp: spawn failed \(error)\n", stderr)
    exit(1)
}
RunLoop.main.run()
