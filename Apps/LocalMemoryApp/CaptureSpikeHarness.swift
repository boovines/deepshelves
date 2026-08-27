import AppKit
import Foundation
import MemoryCapture
import SwiftUI

struct CaptureSpikeTargetView: View {
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate * 5) % 4
                Color(white: phase.isMultiple(of: 2) ? 0.35 : 0.65)
            }
            .ignoresSafeArea()
            .accessibilityLabel("S1 changing crash-integrity target")
        } else {
            Color(red: 0.5, green: 0.5, blue: 0.5)
                .ignoresSafeArea()
                .accessibilityLabel("S1 approved foreground target")
        }
    }
}

@MainActor
enum CaptureSpikeHarness {
    static func run(outputDirectory: URL, durationSeconds: Double, staticMode: Bool) async {
        var windowHarness: CaptureSpikeWindowHarness?
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try writeCorpusManifest(to: outputDirectory)
            windowHarness = installWindows(staticMode: staticMode)
            NSApplication.shared.activate()
            windowHarness?.primary.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1))
            if !staticMode {
                windowHarness?.startCycling()
            }

            let mediaURL = outputDirectory.appendingPathComponent("capture.mov")
            let report = try await CaptureSpikeRunner().run(
                outputURL: mediaURL,
                duration: .seconds(durationSeconds)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(
                to: outputDirectory.appendingPathComponent("report.json"),
                options: .atomic
            )
            try Data().write(
                to: outputDirectory.appendingPathComponent("capture-complete.marker"),
                options: .atomic
            )
            let decodeReport = try await CaptureDecodeBenchmark.run(mediaPaths: report.mediaPaths)
            try encoder.encode(decodeReport).write(
                to: outputDirectory.appendingPathComponent("decode-summary.json"),
                options: .atomic
            )
        } catch {
            let payload = ["error": String(describing: error)]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(
                    to: outputDirectory.appendingPathComponent("error.json"),
                    options: .atomic
                )
            }
        }
        windowHarness?.stop()
        NSApplication.shared.terminate(nil)
    }

    private static func installWindows(staticMode: Bool) -> CaptureSpikeWindowHarness {
        let primary = NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible })
            ?? NSWindow(
                contentRect: NSRect(x: 300, y: 300, width: 720, height: 480),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
        let targetFrame = primary.frame
        let secondary = HarnessWindow(
            contentRect: targetFrame.offsetBy(dx: -80, dy: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        secondary.title = primary.title
        secondary.isOpaque = true
        secondary.backgroundColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        secondary.contentView = staticMode
            ? SolidTargetView(frame: secondary.frame)
            : OfficeCorpusView(frame: secondary.frame)
        secondary.orderBack(nil)

        let sentinelFixtures: [(String, NSRect)] = [
            ("PASSWORD MANAGER", targetFrame.offsetBy(dx: 140, dy: -100)),
            ("PRIVATE BROWSER", targetFrame.offsetBy(dx: -180, dy: 80)),
            ("NOTIFICATION", NSRect(x: targetFrame.maxX - 260, y: targetFrame.maxY - 140, width: 260, height: 140)),
            ("DESKTOP SYSTEM CHROME", NSRect(x: targetFrame.minX, y: targetFrame.minY - 80, width: targetFrame.width, height: 100)),
            ("SPLIT SCREEN NEIGHBOR", NSRect(x: targetFrame.maxX, y: targetFrame.minY, width: targetFrame.width, height: targetFrame.height)),
            ("PREVIOUS FOCUSED WINDOW", targetFrame.offsetBy(dx: 60, dy: 40)),
        ]
        let sentinels = sentinelFixtures.enumerated().map { index, fixture in
            let sentinel = HarnessWindow(
                contentRect: fixture.1,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            sentinel.title = "S1 PROHIBITED \(fixture.0) SENTINEL"
            sentinel.isOpaque = true
            sentinel.backgroundColor = .black
            sentinel.contentView = CheckerboardSentinelView(frame: fixture.1, seed: index)
            sentinel.orderBack(nil)
            return sentinel
        }
        return CaptureSpikeWindowHarness(primary: primary, secondary: secondary, sentinels: sentinels)
    }

    private static func writeCorpusManifest(to outputDirectory: URL) throws {
        let manifest: [String: Any] = [
            "version": 1,
            "scenes": [
                "staticDocument",
                "scrollingDocument",
                "codeEditing",
                "videoLikeMotion",
                "focusSwitch",
                "windowResize",
                "windowMinimizeRestore",
                "duplicateTitle",
                "sleepWakeNotification",
                "prohibitedSentinel",
            ],
            "sentinels": [
                "backgroundPasswordManager",
                "privateBrowser",
                "notification",
                "desktopMenuDockSystemChrome",
                "splitScreenNeighbor",
                "immediatelyPreviousFocusedWindow",
                "excludedFocusedWindow",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("corpus.json"), options: .atomic)
    }
}

@MainActor
private final class CaptureSpikeWindowHarness {
    let primary: NSWindow
    private let secondary: NSWindow
    private let sentinels: [NSWindow]
    private var cycleTask: Task<Void, Never>?

    init(primary: NSWindow, secondary: NSWindow, sentinels: [NSWindow]) {
        self.primary = primary
        self.secondary = secondary
        self.sentinels = sentinels
    }

    func startCycling() {
        cycleTask = Task { @MainActor in
            var phase = 0
            var sentinelIndex = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_200))
                guard !Task.isCancelled else {
                    return
                }
                switch phase % 8 {
                case 0:
                    secondary.makeKeyAndOrderFront(nil)
                case 1:
                    primary.makeKeyAndOrderFront(nil)
                case 2:
                    sentinels[sentinelIndex % sentinels.count].makeKeyAndOrderFront(nil)
                    sentinelIndex += 1
                case 3:
                    primary.makeKeyAndOrderFront(nil)
                case 4:
                    let current = secondary.frame
                    let expanded = current.width < 760
                    secondary.setFrame(
                        NSRect(
                            x: current.minX,
                            y: current.minY,
                            width: expanded ? 800 : 720,
                            height: expanded ? 520 : 480
                        ),
                        display: true
                    )
                    secondary.makeKeyAndOrderFront(nil)
                case 5:
                    secondary.miniaturize(nil)
                    primary.makeKeyAndOrderFront(nil)
                case 6:
                    secondary.deminiaturize(nil)
                    primary.makeKeyAndOrderFront(nil)
                default:
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                    try? await Task.sleep(for: .milliseconds(400))
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                    primary.makeKeyAndOrderFront(nil)
                }
                phase += 1
            }
        }
    }

    func stop() {
        cycleTask?.cancel()
        secondary.close()
        sentinels.forEach { $0.close() }
    }
}

private final class HarnessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SolidTargetView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        bounds.fill()
    }
}

private final class OfficeCorpusView: NSView {
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            refreshTimer?.invalidate()
        }
    }

    @objc private func refresh() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.52, alpha: 1).setFill()
        bounds.fill()
        let tick = Int(Date().timeIntervalSinceReferenceDate * 5)
        let scene = (tick / 25) % 4
        switch scene {
        case 0:
            drawDocument(offset: 0)
        case 1:
            drawDocument(offset: CGFloat(tick % 25) * 6)
        case 2:
            drawCode(offset: CGFloat(tick % 20) * 4)
        default:
            drawVideo(phase: tick)
        }
    }

    private func drawDocument(offset: CGFloat) {
        NSColor(calibratedWhite: 0.68, alpha: 1).setFill()
        for row in 0 ..< 18 {
            NSRect(
                x: 50,
                y: (CGFloat(row) * 24 + offset).truncatingRemainder(dividingBy: bounds.height),
                width: bounds.width * (row.isMultiple(of: 4) ? 0.5 : 0.75),
                height: 7
            ).fill()
        }
    }

    private func drawCode(offset: CGFloat) {
        for row in 0 ..< 22 {
            (row.isMultiple(of: 3)
                ? NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.55, alpha: 1)
                : NSColor(calibratedWhite: 0.36, alpha: 1)).setFill()
            NSRect(
                x: 30 + CGFloat(row % 5) * 14,
                y: (CGFloat(row) * 20 + offset).truncatingRemainder(dividingBy: bounds.height),
                width: bounds.width * 0.6,
                height: 9
            ).fill()
        }
    }

    private func drawVideo(phase: Int) {
        let size: CGFloat = 120
        let travel = max(1, bounds.width - size)
        let x = CGFloat((phase * 17) % Int(travel))
        NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.62, alpha: 1).setFill()
        NSRect(x: x, y: bounds.midY - size / 2, width: size, height: size).fill()
    }
}

private final class CheckerboardSentinelView: NSView {
    private let seed: Int

    init(frame frameRect: NSRect, seed: Int) {
        self.seed = seed
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let columns = 16
        let rows = 12
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                ((row + column + seed) % 2 == 0 ? NSColor.black : NSColor.white).setFill()
                NSRect(
                    x: CGFloat(column) * cellWidth,
                    y: CGFloat(row) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                ).fill()
            }
        }
    }
}
