import AppKit

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
}

if CommandLine.arguments.contains("--inspect-placement") {
    inspectPlacement()
}

if CommandLine.arguments.contains("--probe") {
    runProbe()
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(previewIndex + 1) {
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1])
    renderOverlayPreview(to: outputURL, dark: CommandLine.arguments.contains("--dark"))
}

func resolveProjectDir() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_OVERLAY_DIR"] {
        return URL(fileURLWithPath: override)
    }
    return Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

if CommandLine.arguments.contains("--print-usage") {
    let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)
    let snapshot = UsageSnapshotReader.latest(in: sessionsRoot)
    print("7d=\(snapshot?.sevenDay.map { String(Int($0.rounded())) + "%" } ?? "--")")
    exit(0)
}

let projectDir = resolveProjectDir()

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = OverlayController(projectDir: projectDir)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        controller.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
