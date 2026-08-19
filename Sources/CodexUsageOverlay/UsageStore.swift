import Combine
import Foundation

// MARK: - Geometry and visual tuning

struct Tunables: Decodable, Equatable {
    // Design-space values. The complete content is rendered at 95%, producing
    // an approximately 221 x 30 px visible overlay.
    var barW: CGFloat = 113.684_210_5  // renders as 108 px after the 95% scale
    var groupGap: CGFloat = 5.263_157_9
    var panelH: CGFloat = 30
    var sidePad: CGFloat = 0
    var scale: CGFloat = 0.95
    var centerAboveBottom: CGFloat = 32

    var titleSize: CGFloat = 12
    var valueSize: CGFloat = 12
    var barHeight: CGFloat = 4
    var labelBarGap: CGFloat = 3

    var warnAt: Double = 70
    var dangerAt: Double = 90
    var hideOnOverlap = true
    var overlapMargin: CGFloat = 8
    var appearance = "system"          // system | light | dark

    var contentW: CGFloat {
        barW * 2 + groupGap + sidePad * 2
    }

    var panelW: CGFloat {
        contentW * scale
    }

    var visibleBarW: CGFloat {
        barW * scale
    }

    var unscaledPanelH: CGFloat {
        panelH / max(scale, 0.01)
    }

    private enum CodingKeys: String, CodingKey {
        case barW, groupGap, panelH, sidePad, scale, centerAboveBottom
        case titleSize, valueSize, barHeight, labelBarGap
        case warnAt, dangerAt, hideOnOverlap, overlapMargin, appearance
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Tunables()
        barW = try container.decodeIfPresent(CGFloat.self, forKey: .barW) ?? defaults.barW
        groupGap = try container.decodeIfPresent(CGFloat.self, forKey: .groupGap) ?? defaults.groupGap
        panelH = try container.decodeIfPresent(CGFloat.self, forKey: .panelH) ?? defaults.panelH
        sidePad = try container.decodeIfPresent(CGFloat.self, forKey: .sidePad) ?? defaults.sidePad
        scale = try container.decodeIfPresent(CGFloat.self, forKey: .scale) ?? defaults.scale
        centerAboveBottom = try container.decodeIfPresent(CGFloat.self, forKey: .centerAboveBottom) ?? defaults.centerAboveBottom
        titleSize = try container.decodeIfPresent(CGFloat.self, forKey: .titleSize) ?? defaults.titleSize
        valueSize = try container.decodeIfPresent(CGFloat.self, forKey: .valueSize) ?? defaults.valueSize
        barHeight = try container.decodeIfPresent(CGFloat.self, forKey: .barHeight) ?? defaults.barHeight
        labelBarGap = try container.decodeIfPresent(CGFloat.self, forKey: .labelBarGap) ?? defaults.labelBarGap
        warnAt = try container.decodeIfPresent(Double.self, forKey: .warnAt) ?? defaults.warnAt
        dangerAt = try container.decodeIfPresent(Double.self, forKey: .dangerAt) ?? defaults.dangerAt
        hideOnOverlap = try container.decodeIfPresent(Bool.self, forKey: .hideOnOverlap) ?? defaults.hideOnOverlap
        overlapMargin = try container.decodeIfPresent(CGFloat.self, forKey: .overlapMargin) ?? defaults.overlapMargin
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? defaults.appearance
    }
}

// MARK: - Codex local usage events

struct UsageSnapshot: Equatable {
    let fiveHour: Double?
    let sevenDay: Double?
}

enum UsageSnapshotReader {
    private struct Event: Decodable {
        struct Payload: Decodable {
            let type: String?
            let rateLimits: RateLimits?

            private enum CodingKeys: String, CodingKey {
                case type
                case rateLimits = "rate_limits"
            }
        }

        let timestamp: String?
        let payload: Payload?
    }

    private struct RateLimits: Decodable {
        let limitID: String?
        let primary: Window?
        let secondary: Window?

        private enum CodingKeys: String, CodingKey {
            case limitID = "limit_id"
            case primary, secondary
        }
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }

    static func latest(in sessionsRoot: URL, now: Date = Date()) -> UsageSnapshot? {
        var newest: TimedSnapshot?
        for candidate in candidateRollouts(in: sessionsRoot, now: now) {
            // A local rollout file cannot contain an event newer than its own
            // modification time. Once sorted mtimes fall behind the best event,
            // all remaining files are provably too old and can be skipped.
            if let newestTimestamp = newest?.timestamp,
               candidate.modified < newestTimestamp {
                break
            }
            guard let data = readTail(of: candidate.url),
                  let candidate = parseTimedSnapshot(from: data, now: now) else { continue }
            if let current = newest {
                switch (candidate.timestamp, current.timestamp) {
                case let (candidateTime?, currentTime?) where candidateTime > currentTime:
                    newest = candidate
                case (_?, nil):
                    newest = candidate
                default:
                    break
                }
            } else {
                newest = candidate
            }
        }
        return newest?.snapshot
    }

    static func parseSnapshot(from data: Data, now: Date = Date()) -> UsageSnapshot? {
        parseTimedSnapshot(from: data, now: now)?.snapshot
    }

    private struct TimedSnapshot {
        let timestamp: Date?
        let snapshot: UsageSnapshot
    }

    private static func parseTimedSnapshot(from data: Data, now: Date) -> TimedSnapshot? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(Event.self, from: lineData),
                  event.payload?.type == "token_count",
                  let limits = event.payload?.rateLimits,
                  limits.limitID == nil || limits.limitID == "codex" else { continue }

            var fiveHour: Double?
            var sevenDay: Double?
            for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
                let percent = normalizedPercent(window, now: now)
                switch window.windowMinutes {
                case 240...360:
                    fiveHour = percent
                case 9_000...11_000:
                    sevenDay = percent
                default:
                    continue
                }
            }
            return TimedSnapshot(
                timestamp: parseTimestamp(event.timestamp),
                snapshot: UsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay)
            )
        }
        return nil
    }

    private static func normalizedPercent(_ window: Window, now: Date) -> Double {
        if let resetsAt = window.resetsAt, now.timeIntervalSince1970 >= resetsAt {
            return 0
        }
        return min(max(window.usedPercent, 0), 100)
    }

    private struct RolloutCandidate {
        let url: URL
        let modified: Date
    }

    private static func candidateRollouts(in root: URL, now: Date) -> [RolloutCandidate] {
        let fileManager = FileManager.default
        let calendar = Calendar(identifier: .gregorian)
        var candidates: [(url: URL, modified: Date)] = []

        for dayOffset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year, let month = components.month, let dayNumber = components.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayNumber), isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                candidates.append((file, values.contentModificationDate ?? .distantPast))
            }
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .map { RolloutCandidate(url: $0.url, modified: $0.modified) }
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: raw)
    }

    private static func readTail(of file: URL, maxBytes: UInt64 = 2 * 1_024 * 1_024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // When reading only the tail, discard the first partial JSONL record.
        if offset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
            data = data.suffix(from: data.index(after: firstNewline))
        }
        return data
    }
}

final class UsageStore: ObservableObject {
    @Published private(set) var fiveHour: Double?
    @Published private(set) var sevenDay: Double?
    @Published private(set) var tun = Tunables()

    private let sessionsRoot: URL
    private let tunablesPath: URL
    private var usageTimer: Timer?
    private var tunablesTimer: Timer?
    private var refreshInFlight = false

    init(projectDir: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        sessionsRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        tunablesPath = projectDir.appendingPathComponent("tunables.json")
    }

    func start() {
        refreshTunables()
        refreshUsage()

        usageTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        usageTimer?.tolerance = 2

        tunablesTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshTunables()
        }
        tunablesTimer?.tolerance = 0.5
    }

    func refreshUsage() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let root = sessionsRoot
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = UsageSnapshotReader.latest(in: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                let newFiveHour = snapshot?.fiveHour
                let newSevenDay = snapshot?.sevenDay
                if self.fiveHour != newFiveHour { self.fiveHour = newFiveHour }
                if self.sevenDay != newSevenDay { self.sevenDay = newSevenDay }
            }
        }
    }

    func refreshTunables() {
        var updated = Tunables()
        if let data = try? Data(contentsOf: tunablesPath),
           let decoded = try? JSONDecoder().decode(Tunables.self, from: data) {
            updated = decoded
        }
        guard updated != tun else { return }
        tun = updated
        Log.write("tunables updated: panel=\(String(format: "%.1f", updated.panelW))x\(Int(updated.panelH)) scale=\(updated.scale)")
    }
}

// MARK: - Tiny file logger

enum Log {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CodexUsageOverlay.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: path, atomically: true, encoding: .utf8)
        }
    }
}
