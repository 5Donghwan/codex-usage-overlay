import Foundation

func runSelfTests() -> Never {
    var failures: [String] = []

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    let tunables = Tunables()
    check(abs(tunables.panelW - 221) < 0.05, "default width should be approximately 221 px")
    check(abs(tunables.panelH - 30) < 0.001, "default height should be 30 px")
    check(abs(tunables.scale - 0.95) < 0.001, "default scale should be 95%")
    check(abs(tunables.visibleBarW - 108) < 0.001, "visible bar width should be 10% below 120 px")
    check(abs(tunables.centerAboveBottom - 32) < 0.001, "fallback vertical anchor should be 32 px")
    check(
        tunables.warnAt == 70 && tunables.dangerAt == 90,
        "usage colors should switch at 70 and 90 percent"
    )

    let composer = CGRect(x: 260, y: 878, width: 999, height: 58)
    let modelSelector = CGRect(x: 1_000, y: 899, width: 170, height: 37)
    let panel = OverlayLayout.panelFrame(
        composerFrame: composer,
        modelSelectorFrame: modelSelector,
        tunables: tunables
    )
    check(abs(panel.midX - composer.midX) < 0.001, "overlay should share the composer center")
    check(abs(panel.midY - modelSelector.midY) < 0.001, "overlay center should align with the live model selector")
    check(
        !OverlayLayout.overlapsText(
            panelFrame: panel,
            textFrame: CGRect(x: 334, y: 894, width: 150, height: 26),
            horizontalMargin: tunables.overlapMargin
        ),
        "compact left-aligned placeholder should leave the centered overlay clear"
    )
    check(
        OverlayLayout.overlapsText(
            panelFrame: panel,
            textFrame: CGRect(x: 334, y: 894, width: 600, height: 26),
            horizontalMargin: tunables.overlapMargin
        ),
        "long compact input text reaching the center should hide the overlay"
    )
    let unavailableValueFrames = TextObstaclePolicy.frames(
        value: nil,
        placeholder: nil,
        inputFrame: CGRect(x: 334, y: 894, width: 732, height: 26),
        exactValueBounds: nil
    )
    check(
        unavailableValueFrames == [CGRect(x: 334, y: 894, width: 732, height: 26)],
        "unavailable AX value should reserve the full input frame"
    )
    let echoedPlaceholderFrames = TextObstaclePolicy.frames(
        value: "\n무엇이든 요청하세요",
        placeholder: "무엇이든 요청하세요",
        inputFrame: CGRect(x: 334, y: 894, width: 732, height: 26),
        exactValueBounds: CGRect(x: 334, y: 894, width: 732, height: 26)
    )
    check(
        echoedPlaceholderFrames.allSatisfy {
            !OverlayLayout.overlapsText(
                panelFrame: panel,
                textFrame: $0,
                horizontalMargin: tunables.overlapMargin
            )
        },
        "AX values that echo the description should leave the compact overlay clear"
    )
    let converted = OverlayLayout.appKitFrame(
        from: CGRect(x: 649, y: -100, width: 221, height: 30),
        primaryScreenMaxY: 956
    )
    check(converted.origin == CGPoint(x: 649, y: 1_026), "negative AX coordinates should convert across displays")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dualWindowLine = """
    {"payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42.4,"window_minutes":300,"resets_at":1800000300},"secondary":{"used_percent":84.2,"window_minutes":10080,"resets_at":1800000300}}}}
    """
    let dualWindow = UsageSnapshotReader.parseSnapshot(from: Data(dualWindowLine.utf8), now: now)
    check(dualWindow?.fiveHour == 42.4, "five-hour usage should parse")
    check(dualWindow?.sevenDay == 84.2, "seven-day usage should parse")

    let expiredLine = """
    {"payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":84,"window_minutes":10080,"resets_at":1799999999},"secondary":null}}}
    """
    let expired = UsageSnapshotReader.parseSnapshot(from: Data(expiredLine.utf8), now: now)
    check(expired?.fiveHour == nil, "missing five-hour usage should stay unknown")
    check(expired?.sevenDay == 0, "expired usage should reset to zero")

    let latestLines = """
    {"payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":20,"window_minutes":10080,"resets_at":1800000300}}}}
    {"payload":{"type":"message","text":"ignore"}}
    {"payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":36,"window_minutes":10080,"resets_at":1800000300}}}}
    """
    let latest = UsageSnapshotReader.parseSnapshot(from: Data(latestLines.utf8), now: now)
    check(latest?.sevenDay == 36, "latest token-count event should win")

    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("codex-overlay-self-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents([.year, .month, .day], from: Date())
    if let year = components.year, let month = components.month, let day = components.day {
        let dayDirectory = temporaryRoot
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        do {
            try fileManager.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
            let olderEvent = """
            {"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":11,"window_minutes":10080,"resets_at":2000000000}}}}
            """
            let newerEvent = """
            {"timestamp":"2026-01-02T00:00:00.100Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":22,"window_minutes":10080,"resets_at":2000000000}}}}
            """
            let newerMtimeFile = dayDirectory.appendingPathComponent("older-usage.jsonl")
            let olderMtimeFile = dayDirectory.appendingPathComponent("newer-usage.jsonl")
            try Data(olderEvent.utf8).write(to: newerMtimeFile)
            try Data(newerEvent.utf8).write(to: olderMtimeFile)
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: newerMtimeFile.path)
            try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: olderMtimeFile.path)
            for index in 0..<17 {
                let decoy = dayDirectory.appendingPathComponent("decoy-\(index).jsonl")
                try Data(olderEvent.utf8).write(to: decoy)
                try fileManager.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(TimeInterval(-index))],
                    ofItemAtPath: decoy.path
                )
            }
            let globallyNewest = UsageSnapshotReader.latest(in: temporaryRoot)
            check(
                globallyNewest?.sevenDay == 22,
                "mixed-precision event timestamps should beat 17+ newer-mtime decoys"
            )
        } catch {
            failures.append("timestamp ordering fixture failed: \(error)")
        }
    } else {
        failures.append("calendar fixture setup failed")
    }

    if failures.isEmpty {
        print("self-test passed (19 checks)")
        exit(0)
    }
    for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
    }
    exit(1)
}
