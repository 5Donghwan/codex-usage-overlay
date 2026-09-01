import AppKit
import SwiftUI

struct BarGroup: View {
    let title: String
    let percent: Double?
    let tunables: Tunables
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: tunables.labelBarGap) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: tunables.titleSize, weight: .regular, design: .default))
                    .foregroundStyle(Color.primary.opacity(0.92))
                Spacer(minLength: 0)
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: tunables.valueSize, weight: .regular, design: .default))
                    .foregroundStyle(
                        percent == nil
                            ? AnyShapeStyle(Color.primary.opacity(0.62))
                            : AnyShapeStyle(Color.primary.opacity(0.96))
                    )
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.28 : 0.14))
                if let percent {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Palette.fill(
                                for: percent,
                                warnAt: tunables.warnAt,
                                dangerAt: tunables.dangerAt,
                                dark: colorScheme == .dark
                            ))
                            .frame(width: geometry.size.width * min(max(percent, 0), 100) / 100)
                    }
                }
            }
            .frame(height: tunables.barHeight)
        }
        .frame(width: tunables.barW)
    }
}

struct OverlayContent: View {
    let fiveHour: Double?
    let sevenDay: Double?
    let tunables: Tunables

    var body: some View {
        HStack(spacing: tunables.groupGap) {
            BarGroup(title: "5h", percent: fiveHour, tunables: tunables)
            BarGroup(title: "7d", percent: sevenDay, tunables: tunables)
        }
        .padding(.horizontal, tunables.sidePad)
        .frame(width: tunables.contentW, height: tunables.unscaledPanelH)
        .scaleEffect(tunables.scale, anchor: .center)
        .frame(width: tunables.panelW, height: tunables.panelH)
    }
}

struct OverlayView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        OverlayContent(
            fiveHour: store.fiveHour,
            sevenDay: store.sevenDay,
            tunables: store.tun
        )
    }
}

enum OverlayLayout {
    static func panelFrame(
        composerFrame: CGRect,
        modelSelectorFrame: CGRect? = nil,
        tunables: Tunables
    ) -> CGRect {
        let centerY = modelSelectorFrame?.midY
            ?? composerFrame.maxY - tunables.centerAboveBottom
        return CGRect(
            x: composerFrame.midX - tunables.panelW / 2,
            y: centerY - tunables.panelH / 2,
            width: tunables.panelW,
            height: tunables.panelH
        )
    }

    static func overlapsText(
        panelFrame: CGRect,
        textFrame: CGRect,
        horizontalMargin: CGFloat
    ) -> Bool {
        textFrame.intersects(panelFrame.insetBy(dx: -horizontalMargin, dy: 0))
    }

    static func appKitFrame(from panelAX: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: panelAX.minX,
            y: primaryScreenMaxY - panelAX.maxY,
            width: panelAX.width,
            height: panelAX.height
        )
    }
}

func renderOverlayPreview(to outputURL: URL, dark: Bool) -> Never {
    let tunables = Tunables()
    let background = dark
        ? Color(.sRGB, red: 0.145, green: 0.145, blue: 0.145, opacity: 1)
        : Color(.sRGB, red: 0.985, green: 0.985, blue: 0.985, opacity: 1)
    let rootView = OverlayContent(
        fiveHour: nil,
        sevenDay: 84,
        tunables: tunables
    )
    .background(background)
    .environment(\.colorScheme, dark ? .dark : .light)

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(x: 0, y: 0, width: tunables.panelW, height: tunables.panelH)
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()

    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        fputs("failed to allocate preview bitmap\n", stderr)
        exit(1)
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("failed to encode preview PNG\n", stderr)
        exit(1)
    }
    do {
        try png.write(to: outputURL, options: .atomic)
        print("rendered: \(outputURL.path)")
        exit(0)
    } catch {
        fputs("preview write failed: \(error)\n", stderr)
        exit(1)
    }
}

final class OverlayController: NSObject {
    private let store: UsageStore
    private let tracker = CodexTracker()
    private var panel: NSPanel!
    private var pollTimer: Timer?
    private var lastOverlapScan = Date.distantPast
    private var cachedObstacles: [CGRect] = []
    private var obstacleComposerFrame: CGRect?
    private var obstacleRelativeInputFrame: CGRect?
    private var obstacleContainer: AXUIElement?
    private var wasBlocked = false
    private var appliedAppearance = ""

    init(projectDir: URL) {
        store = UsageStore(projectDir: projectDir)
        super.init()
    }

    func start() {
        makePanel()
        store.start()
        ensureAccessibilityThenRun()
    }

    private func makePanel() {
        let tunables = store.tun
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: tunables.panelW, height: tunables.panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(store: store))
        self.panel = panel
    }

    private func ensureAccessibilityThenRun() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            Log.write("accessibility granted; tracking started")
            beginPolling()
            return
        }
        Log.write("waiting for accessibility permission")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            Log.write("accessibility granted; tracking started")
            self?.beginPolling()
        }
    }

    private func beginPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.03
        pollTimer = timer
    }

    private func tick() {
        guard let codex = tracker.codexApp(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == codex.processIdentifier,
              let placement = tracker.inputPlacement() else {
            hide()
            return
        }

        let tunables = store.tun
        let panelAX = OverlayLayout.panelFrame(
            composerFrame: placement.composerFrame,
            modelSelectorFrame: placement.modelSelectorFrame,
            tunables: tunables
        )
        applyAppearance(tunables.appearance)

        guard placement.composerFrame.width >= tunables.panelW + tunables.overlapMargin * 2 else {
            hide()
            return
        }

        if tunables.hideOnOverlap,
           isBlocked(panelAX, placement: placement, tunables: tunables) {
            if !wasBlocked {
                wasBlocked = true
                Log.write("hidden: overlay would cover a composer control")
            }
            hide()
            return
        }
        if wasBlocked {
            wasBlocked = false
            Log.write("shown: composer center is clear")
        }

        // Accessibility uses a top-left origin relative to the primary display;
        // AppKit uses a bottom-left origin. This transform remains valid when the
        // Codex window moves between displays or changes size.
        guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first else { return }
        let frame = OverlayLayout.appKitFrame(
            from: panelAX,
            primaryScreenMaxY: primaryScreen.frame.maxY
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func isBlocked(
        _ panelFrame: CGRect,
        placement: CodexTracker.Placement,
        tunables: Tunables
    ) -> Bool {
        if placement.textFrames.contains(where: {
            OverlayLayout.overlapsText(
                panelFrame: panelFrame,
                textFrame: $0,
                horizontalMargin: tunables.overlapMargin
            )
        }) {
            return true
        }
        // If the host tree is changing and the composer container disappears,
        // hide briefly rather than risk drawing over an unknown control.
        guard let container = placement.container else { return true }
        let composerFrame = placement.composerFrame
        let previousFrame = obstacleComposerFrame
        let relativeInputFrame = placement.inputFrame.offsetBy(
            dx: -composerFrame.minX,
            dy: -composerFrame.minY
        )
        let containerChanged = obstacleContainer.map { !CFEqual($0, container) } ?? true
        let composerResized = previousFrame?.size != composerFrame.size
        let inputChanged = obstacleRelativeInputFrame != relativeInputFrame
        if containerChanged || composerResized || inputChanged
            || Date().timeIntervalSince(lastOverlapScan) > 0.5 {
            lastOverlapScan = Date()
            cachedObstacles = tracker.toolbarFrames(
                in: container,
                verticalBand: panelFrame.minY...panelFrame.maxY
            )
            obstacleComposerFrame = composerFrame
            obstacleRelativeInputFrame = relativeInputFrame
            obstacleContainer = container
        } else if let previousFrame, previousFrame.origin != composerFrame.origin {
            // During a window drag, translate the cached control frames by the
            // same delta as the composer. A resize triggers a fresh AX scan.
            let dx = composerFrame.minX - previousFrame.minX
            let dy = composerFrame.minY - previousFrame.minY
            cachedObstacles = cachedObstacles.map { $0.offsetBy(dx: dx, dy: dy) }
            obstacleComposerFrame = composerFrame
        }
        let paddedPanel = panelFrame.insetBy(dx: -tunables.overlapMargin, dy: 0)
        return cachedObstacles.contains { $0.intersects(paddedPanel) }
    }

    private func applyAppearance(_ preference: String) {
        guard preference != appliedAppearance else { return }
        appliedAppearance = preference
        switch preference.lowercased() {
        case "light":
            panel.appearance = NSAppearance(named: .aqua)
        case "dark":
            panel.appearance = NSAppearance(named: .darkAqua)
        default:
            panel.appearance = nil
        }
    }

    private func hide() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
