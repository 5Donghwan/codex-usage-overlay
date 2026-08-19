import AppKit
import ApplicationServices

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let array = value as? [AnyObject] else { return [] }
    return array.compactMap {
        CFGetTypeID($0 as CFTypeRef) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
    }
}

func axBoundsForRange(_ element: AXUIElement, utf16Length: Int) -> CGRect? {
    guard utf16Length > 0 else { return nil }
    var range = CFRange(location: 0, length: utf16Length)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        rangeValue,
        &value
    ) == .success,
    let value,
    CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var bounds = CGRect.zero
    guard AXValueGetValue(value as! AXValue, .cgRect, &bounds),
          bounds.width > 0,
          bounds.height > 0 else { return nil }
    return bounds
}

/// Global screen coordinates using Accessibility's top-left origin.
func axFrame(_ element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue,
          let sizeValue,
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: position, size: size)
}

let codexBundleID = "com.openai.codex"

enum TextObstaclePolicy {
    static func frames(
        value: String?,
        placeholder: String?,
        inputFrame: CGRect,
        exactValueBounds: CGRect?
    ) -> [CGRect] {
        guard let value else {
            // AX read/type failure is not proof that the field is empty.
            return [inputFrame]
        }
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPlaceholder = placeholder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueEchoesPlaceholder = !normalizedValue.isEmpty
            && normalizedValue == normalizedPlaceholder

        if !normalizedValue.isEmpty && !valueEchoesPlaceholder {
            if let exactValueBounds {
                return [exactValueBounds.insetBy(dx: -2, dy: -1)]
            }
            return [inputFrame]
        }

        guard let placeholder = normalizedPlaceholder, !placeholder.isEmpty else { return [] }
        let measuredWidth = (placeholder as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).width
        let estimatedWidth = min(inputFrame.width, max(40, measuredWidth + 16))
        return [CGRect(
            x: inputFrame.minX,
            y: inputFrame.minY,
            width: estimatedWidth,
            height: inputFrame.height
        )]
    }
}

final class CodexTracker {
    struct Placement {
        let inputFrame: CGRect
        let textFrames: [CGRect]
        let composerFrame: CGRect
        let modelSelectorFrame: CGRect?
        let container: AXUIElement?
    }

    private var pid: pid_t = -1
    private var appElement: AXUIElement?
    private var inputElement: AXUIElement?
    private var trackedWindow: AXUIElement?
    private var lastSearch = Date.distantPast
    private var loggedInput = false
    private var treeReadyAt = Date.distantPast

    func codexApp() -> NSRunningApplication? {
        if pid > 0,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            return app
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == codexBundleID
        }) else {
            pid = -1
            appElement = nil
            inputElement = nil
            trackedWindow = nil
            return nil
        }

        pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        appElement = element
        inputElement = nil
        trackedWindow = nil
        loggedInput = false
        treeReadyAt = Date().addingTimeInterval(0.6)
        return app
    }

    func inputPlacement() -> Placement? {
        guard Date() >= treeReadyAt else { return nil }
        guard let appElement,
              let window = axElement(appElement, kAXFocusedWindowAttribute)
                ?? axElement(appElement, kAXMainWindowAttribute)
                ?? axElements(appElement, kAXWindowsAttribute).first else {
            inputElement = nil
            trackedWindow = nil
            return nil
        }

        if let trackedWindow, !CFEqual(trackedWindow, window) {
            inputElement = nil
            loggedInput = false
        }
        trackedWindow = window

        if let inputElement,
           let inputFrame = axFrame(inputElement),
           inputFrame.width >= 250 {
            let composer = composer(for: inputElement, inputFrame: inputFrame)
            return Placement(
                inputFrame: inputFrame,
                textFrames: textFrames(for: inputElement, inputFrame: inputFrame),
                composerFrame: composer.frame,
                modelSelectorFrame: composer.container.flatMap {
                    modelSelectorFrame(in: $0, composerFrame: composer.frame)
                },
                container: composer.container
            )
        }
        self.inputElement = nil

        guard Date().timeIntervalSince(lastSearch) > 1 else { return nil }
        lastSearch = Date()
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let (element, frame) = Self.findInputArea(in: window) else { return nil }
        inputElement = element
        let composer = composer(for: element, inputFrame: frame)
        if !loggedInput {
            Log.write(
                "input found at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)); "
                    + "composer \(Int(composer.frame.minX)),\(Int(composer.frame.minY)) \(Int(composer.frame.width))x\(Int(composer.frame.height))"
            )
            loggedInput = true
        }
        return Placement(
            inputFrame: frame,
            textFrames: textFrames(for: element, inputFrame: frame),
            composerFrame: composer.frame,
            modelSelectorFrame: composer.container.flatMap {
                modelSelectorFrame(in: $0, composerFrame: composer.frame)
            },
            container: composer.container
        )
    }

    private func textFrames(for input: AXUIElement, inputFrame: CGRect) -> [CGRect] {
        let value = axString(input, kAXValueAttribute)
        let placeholder = axString(input, "AXPlaceholderValue")
            ?? axString(input, kAXDescriptionAttribute)
        let exactBounds = value.flatMap { text in
            text.isEmpty ? nil : axBoundsForRange(input, utf16Length: text.utf16.count)
        }
        return TextObstaclePolicy.frames(
            value: value,
            placeholder: placeholder,
            inputFrame: inputFrame,
            exactValueBounds: exactBounds
        )
    }

    static func findInputArea(in window: AXUIElement) -> (AXUIElement, CGRect)? {
        guard let windowFrame = axFrame(window) else { return nil }
        var queue: [AXUIElement] = [window]
        var index = 0
        var best: (element: AXUIElement, frame: CGRect, score: CGFloat)?

        while index < queue.count && queue.count < 8_000 {
            let element = queue[index]
            index += 1
            if let role = axString(element, kAXRoleAttribute),
               role == "AXTextArea" || role == "AXTextField",
               let frame = axFrame(element),
               frame.width >= 250,
               frame.height >= 18,
               frame.height < windowFrame.height * 0.55,
               frame.midY > windowFrame.midY,
               frame.maxY <= windowFrame.maxY + 2 {
                let lowerPosition = (frame.midY - windowFrame.midY) / max(windowFrame.height / 2, 1)
                let widthShare = frame.width / max(windowFrame.width, 1)
                let placeholder = (
                    axString(element, "AXPlaceholderValue")
                        ?? axString(element, kAXDescriptionAttribute)
                        ?? ""
                ).lowercased()
                let composerHint = ["message", "request", "prompt", "ask", "요청", "메시지"]
                    .contains { placeholder.contains($0) } ? CGFloat(500) : 0
                let score = lowerPosition * 1_000 + widthShare * 200 + composerHint
                if best == nil || score > best!.score {
                    best = (element, frame, score)
                }
            }
            queue.append(contentsOf: axElements(element, kAXChildrenAttribute))
        }
        return best.map { ($0.element, $0.frame) }
    }

    func composer(for input: AXUIElement, inputFrame: CGRect) -> (frame: CGRect, container: AXUIElement?) {
        var element = input
        var fallbackElement: AXUIElement?
        var fallbackFrame = CGRect(
            x: inputFrame.minX - 16,
            y: inputFrame.minY - 12,
            width: inputFrame.width + 32,
            height: inputFrame.height + 60
        )

        for _ in 0..<10 {
            guard let parent = axElement(element, kAXParentAttribute) else { break }
            if let parentFrame = axFrame(parent) {
                let bottomExtension = parentFrame.maxY - inputFrame.maxY
                let widthRatio = parentFrame.width / max(inputFrame.width, 1)
                if bottomExtension > 130 || widthRatio > 1.55 { break }
                if parentFrame.width >= inputFrame.width,
                   bottomExtension >= 14,
                   bottomExtension <= 110 {
                    fallbackElement = parent
                    fallbackFrame = parentFrame
                    if bottomExtension >= 28, widthRatio <= 1.25 {
                        return (parentFrame, parent)
                    }
                }
            }
            element = parent
        }
        return (fallbackFrame, fallbackElement)
    }

    func toolbarFrames(in container: AXUIElement, verticalBand: ClosedRange<CGFloat>) -> [CGRect] {
        let controlRoles: Set<String> = [
            "AXButton", "AXPopUpButton", "AXStaticText", "AXMenuButton", "AXComboBox",
            "AXCheckBox", "AXRadioButton", "AXImage",
        ]
        var queue: [AXUIElement] = [container]
        var index = 0
        var frames: [CGRect] = []

        while index < queue.count && queue.count < 1_500 {
            let element = queue[index]
            index += 1
            if let role = axString(element, kAXRoleAttribute),
               controlRoles.contains(role),
               let frame = axFrame(element),
               frame.width > 0,
               frame.height > 0,
               frame.maxY >= verticalBand.lowerBound,
               frame.minY <= verticalBand.upperBound {
                frames.append(frame)
            }
            queue.append(contentsOf: axElements(element, kAXChildrenAttribute))
        }
        return frames
    }

    func modelSelectorFrame(in container: AXUIElement, composerFrame: CGRect) -> CGRect? {
        var queue: [AXUIElement] = [container]
        var index = 0
        var rightmost: CGRect?

        while index < queue.count && queue.count < 1_500 {
            let element = queue[index]
            index += 1
            if axString(element, kAXRoleAttribute) == "AXPopUpButton",
               let frame = axFrame(element),
               frame.width >= 40,
               frame.height >= 28,
               frame.height <= 44,
               frame.midX > composerFrame.midX,
               frame.minY >= composerFrame.minY - 2,
               frame.maxY <= composerFrame.maxY + 2,
               rightmost == nil || frame.midX > rightmost!.midX {
                rightmost = frame
            }
            queue.append(contentsOf: axElements(element, kAXChildrenAttribute))
        }
        return rightmost
    }
}

func runProbe() -> Never {
    guard AXIsProcessTrusted() else {
        print("NOT TRUSTED: grant Accessibility permission to CodexUsageOverlay first")
        exit(2)
    }
    guard let codex = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == codexBundleID
    }) else {
        print("Codex desktop app is not running")
        exit(3)
    }

    let appElement = AXUIElementCreateApplication(codex.processIdentifier)
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 1)
    guard let window = axElement(appElement, kAXFocusedWindowAttribute)
            ?? axElement(appElement, kAXMainWindowAttribute)
            ?? axElements(appElement, kAXWindowsAttribute).first else {
        print("No Codex window")
        exit(4)
    }

    print("window frame: \(axFrame(window).map(String.init(describing:)) ?? "?")")
    var lines = 0
    func dump(_ element: AXUIElement, depth: Int) {
        guard lines < 2_500, depth < 30 else { return }
        let role = axString(element, kAXRoleAttribute) ?? "?"
        let interesting: Set<String> = [
            "AXTextArea", "AXTextField", "AXButton", "AXGroup", "AXWebArea",
            "AXPopUpButton", "AXComboBox", "AXStaticText",
        ]
        if interesting.contains(role), let frame = axFrame(element) {
            let padding = String(repeating: " ", count: min(depth, 40))
            let title = axString(element, kAXTitleAttribute)
                ?? axString(element, "AXPlaceholderValue")
                ?? axString(element, kAXDescriptionAttribute)
                ?? ""
            print("\(padding)\(role) [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))] \(title.prefix(64))")
            lines += 1
        }
        for child in axElements(element, kAXChildrenAttribute) {
            dump(child, depth: depth + 1)
        }
    }
    dump(window, depth: 0)

    if let (element, frame) = CodexTracker.findInputArea(in: window) {
        let composer = CodexTracker().composer(for: element, inputFrame: frame)
        print("\nCHOSEN input: \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        print("CHOSEN composer: \(Int(composer.frame.minX)),\(Int(composer.frame.minY)) \(Int(composer.frame.width))x\(Int(composer.frame.height))")
        for attribute in [kAXValueAttribute as String, "AXPlaceholderValue", kAXDescriptionAttribute as String, "AXNumberOfCharacters", kAXSelectedTextAttribute as String] {
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
            print("input \(attribute): result=\(result.rawValue) value=\(raw.map { String(describing: $0) } ?? "nil")")
        }
        var ancestor = element
        for level in 1...10 {
            guard let parent = axElement(ancestor, kAXParentAttribute) else { break }
            let role = axString(parent, kAXRoleAttribute) ?? "?"
            print("ancestor \(level): \(role) \(axFrame(parent).map(String.init(describing:)) ?? "?")")
            ancestor = parent
        }
    } else {
        print("\nNO input area matched")
    }
    exit(0)
}

func inspectPlacement() -> Never {
    guard AXIsProcessTrusted() else {
        print("NOT TRUSTED: grant Accessibility permission to CodexUsageOverlay first")
        exit(2)
    }
    let tracker = CodexTracker()
    guard tracker.codexApp() != nil else {
        print("Codex desktop app is not running")
        exit(3)
    }
    Thread.sleep(forTimeInterval: 0.8)
    guard
          let placement = tracker.inputPlacement() else {
        print("Codex composer not found")
        exit(4)
    }

    let tunables = Tunables()
    let panelFrame = OverlayLayout.panelFrame(
        composerFrame: placement.composerFrame,
        modelSelectorFrame: placement.modelSelectorFrame,
        tunables: tunables
    )
    let obstacles = placement.container.map {
        tracker.toolbarFrames(in: $0, verticalBand: panelFrame.minY...panelFrame.maxY)
    } ?? []
    let paddedPanel = panelFrame.insetBy(dx: -tunables.overlapMargin, dy: 0)
    let controlCollisions = obstacles.filter { $0.intersects(paddedPanel) }
    let textCollisions = placement.textFrames.filter {
        OverlayLayout.overlapsText(
            panelFrame: panelFrame,
            textFrame: $0,
            horizontalMargin: tunables.overlapMargin
        )
    }
    let wouldHide = !textCollisions.isEmpty || !controlCollisions.isEmpty

    print("input=\(formatFrame(placement.inputFrame))")
    print("composer=\(formatFrame(placement.composerFrame))")
    print("modelSelector=\(placement.modelSelectorFrame.map(formatFrame) ?? "not-found")")
    print("overlay=\(formatFrame(panelFrame))")
    print("composerCenterX=\(Int(placement.composerFrame.midX.rounded())) overlayCenterX=\(Int(panelFrame.midX.rounded()))")
    if let modelSelectorFrame = placement.modelSelectorFrame {
        print("modelCenterY=\(String(format: "%.1f", modelSelectorFrame.midY)) overlayCenterY=\(String(format: "%.1f", panelFrame.midY))")
    }
    print("bottomToOverlayCenter=\(Int((placement.composerFrame.maxY - panelFrame.midY).rounded()))")
    print("toolbarObstaclesInBand=\(obstacles.count) controlCollisions=\(controlCollisions.count)")
    print("textObstacles=\(placement.textFrames.count) textCollisions=\(textCollisions.count) wouldHide=\(wouldHide)")
    if !placement.textFrames.isEmpty {
        print("textObstacleFrames=\(placement.textFrames.map(formatFrame).joined(separator: ","))")
    }
    exit(0)
}

private func formatFrame(_ frame: CGRect) -> String {
    "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())) \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
}
