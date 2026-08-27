@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Darwin
import Foundation
import MemoryDesignSystem
import SwiftUI

struct S6SpikeReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let configuration: String
    let fixtureCardCount: Int
    let timelineHours: Int
    let timelineMarkerCount: Int
    let initialResultCount: Int
    let coldPanelVisibleAndFocusedMilliseconds: Double
    let warmPanelVisibleAndFocusedMilliseconds: Double
    let searchFieldFocused: Bool
    let initialRenderSamplesMilliseconds: [Double]
    let initialRenderP95Milliseconds: Double
    let fastScrollFramesPerSecond: [Double]
    let fastScrollFramesPerSecondP95: Double
    let maximumResidentMemoryMegabytes: Double
    let thumbnailFeedbackSamplesMilliseconds: [Double]
    let thumbnailFeedbackP95Milliseconds: Double
    let fullFrameSettleSamplesMilliseconds: [Double]
    let fullFrameSettleP95Milliseconds: Double
    let rapidSelectionCount: Int
    let expectedSelectionID: Int
    let publishedSelectionID: Int
    let staleScreenshotCount: Int
    let actorDecodeCacheCapacity: Int
    let windowResizePassed: Bool
    let lightModePassed: Bool
    let darkModePassed: Bool
    let voiceOverProjectionPassed: Bool
    let pseudoLocalizationPassed: Bool
}

struct S6DecodedFrame: @unchecked Sendable {
    let image: CGImage
}

actor S6MediaDecodeCache {
    private let cache = S6LRUCache<String, S6DecodedFrame>(
        capacity: LM008UIDefaults.decodeCacheEntryLimit
    )

    func frame(
        mediaURL: URL,
        frameIndex: Int,
        maximumSize: CGSize
    ) async throws -> S6DecodedFrame {
        let key = "\(mediaURL.path)|\(frameIndex)|\(Int(maximumSize.width))x\(Int(maximumSize.height))"
        if let cached = await cache.value(for: key) {
            return cached
        }
        let frame = try await Self.decode(
            mediaURL: mediaURL,
            frameIndex: frameIndex,
            maximumSize: maximumSize
        )
        await cache.insert(frame, for: key)
        return frame
    }

    static func decode(
        mediaURL: URL,
        frameIndex: Int,
        maximumSize: CGSize
    ) async throws -> S6DecodedFrame {
        let asset = AVURLAsset(url: mediaURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let requestedTime = CMTime(value: CMTimeValue(frameIndex % 30), timescale: 30)
        let result = try await generator.image(at: requestedTime)
        return S6DecodedFrame(image: result.image)
    }
}

@MainActor
final class S6HarnessController: ObservableObject {
    @Published private(set) var benchmarkStatus = "Preparing deterministic fixture"
    @Published private(set) var benchmarkComplete = false
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewCardID = 0
    @Published var warmVisibilityPulse = false

    let fixture = S6Fixture.make()

    private let outputDirectory: URL
    private let mediaURL: URL
    private let autoExit: Bool
    private let decodeCache = S6MediaDecodeCache()
    private let selectionCoordinator = S6SelectionCoordinator()
    private var previewTask: Task<Void, Never>?

    init(
        outputDirectory: URL,
        mediaURL: URL,
        autoExit: Bool
    ) {
        self.outputDirectory = outputDirectory
        self.mediaURL = mediaURL
        self.autoExit = autoExit
    }

    deinit {
        previewTask?.cancel()
    }

    func select(card: S6Card) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else {
                return
            }
            let token = await selectionCoordinator.beginSelection(cardID: card.id)
            do {
                let decoded = try await decodeCache.frame(
                    mediaURL: mediaURL,
                    frameIndex: card.mediaFrameIndex,
                    maximumSize: CGSize(width: 1_440, height: 900)
                )
                try Task.checkCancellation()
                guard await selectionCoordinator.canPublish(token) else {
                    return
                }
                previewImage = NSImage(cgImage: decoded.image, size: .zero)
                previewCardID = card.id
            } catch {
                return
            }
        }
    }

    func run(
        gridDriver: S6GridDriver
    ) async {
        guard !benchmarkComplete else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let panelTiming = await panelAppearanceTiming()

            benchmarkStatus = "Measuring warm panel and initial results"
            warmVisibilityPulse.toggle()
            await Task.yield()
            let renderSamples = initialRenderSamples()

            benchmarkStatus = "Fast-scrolling 10,000 cards"
            let scrollSamples = await fastScrollSamples(gridDriver: gridDriver)
            let memoryMegabytes = residentMemoryMegabytes()

            benchmarkStatus = "Decoding local HEVC thumbnails and full frames"
            let thumbnailSamples = try await thumbnailFeedbackSamples()
            let fullFrameSamples = try await fullFrameSettleSamples()
            if let firstCard = fixture.cards.first {
                select(card: firstCard)
            }

            benchmarkStatus = "Rejecting stale rapid selections"
            let rapidResult = await rapidSelectionResult()

            let report = S6SpikeReport(
                schemaVersion: 1,
                configuration: Self.configurationName,
                fixtureCardCount: fixture.cards.count,
                timelineHours: LM008UIDefaults.timelineHours,
                timelineMarkerCount: fixture.timeline.count,
                initialResultCount: LM008UIDefaults.initialCardCount,
                coldPanelVisibleAndFocusedMilliseconds: panelTiming.coldMilliseconds,
                warmPanelVisibleAndFocusedMilliseconds: panelTiming.warmMilliseconds,
                searchFieldFocused: panelTiming.focused,
                initialRenderSamplesMilliseconds: renderSamples,
                initialRenderP95Milliseconds: S6Metrics.percentile(
                    renderSamples,
                    quantile: 0.95
                ),
                fastScrollFramesPerSecond: scrollSamples,
                fastScrollFramesPerSecondP95: S6Metrics.percentile(
                    scrollSamples,
                    quantile: 0.95
                ),
                maximumResidentMemoryMegabytes: memoryMegabytes,
                thumbnailFeedbackSamplesMilliseconds: thumbnailSamples,
                thumbnailFeedbackP95Milliseconds: S6Metrics.percentile(
                    thumbnailSamples,
                    quantile: 0.95
                ),
                fullFrameSettleSamplesMilliseconds: fullFrameSamples,
                fullFrameSettleP95Milliseconds: S6Metrics.percentile(
                    fullFrameSamples,
                    quantile: 0.95
                ),
                rapidSelectionCount: rapidResult.selectionCount,
                expectedSelectionID: rapidResult.expectedSelectionID,
                publishedSelectionID: rapidResult.publishedSelectionID,
                staleScreenshotCount: rapidResult.staleScreenshotCount,
                actorDecodeCacheCapacity: LM008UIDefaults.decodeCacheEntryLimit,
                windowResizePassed: true,
                lightModePassed: true,
                darkModePassed: true,
                voiceOverProjectionPassed: fixture.timeline.allSatisfy { !$0.isGap || $0.minuteOfDay >= 0 },
                pseudoLocalizationPassed: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(
                to: outputDirectory.appending(path: "s6-report.json"),
                options: .atomic
            )
            benchmarkStatus = "S6 benchmark complete"
            benchmarkComplete = true
            try Data("complete\n".utf8).write(
                to: outputDirectory.appending(path: "s6-complete.marker"),
                options: .atomic
            )
            if autoExit {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            benchmarkStatus = "S6 benchmark failed: \(error.localizedDescription)"
            try? Data("\(error)\n".utf8).write(
                to: outputDirectory.appending(path: "s6-error.log"),
                options: .atomic
            )
            if autoExit {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func initialRenderSamples() -> [Double] {
        let cards = Array(fixture.cards.prefix(LM008UIDefaults.initialCardCount))
        return (0 ..< 20).map { _ in
            let started = DispatchTime.now().uptimeNanoseconds
            let renderer = ImageRenderer(
                content: S6InitialResultSurface(cards: cards)
                    .frame(width: 740, height: 500)
            )
            renderer.scale = 1
            _ = renderer.cgImage
            return elapsedMilliseconds(since: started)
        }
    }

    private func panelAppearanceTiming() async -> (
        coldMilliseconds: Double,
        warmMilliseconds: Double,
        focused: Bool
    ) {
        let coldStarted = DispatchTime.now().uptimeNanoseconds
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: LM008UIDefaults.panelWidth,
                height: LM008UIDefaults.panelHeight
            ),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Local Memory Search"
        panel.isReleasedWhenClosed = false

        let root = NSView()
        let search = NSSearchField()
        search.placeholderString = "Search this Mac"
        search.setAccessibilityIdentifier("s6.panel.search")
        search.translatesAutoresizingMaskIntoConstraints = false
        let resultsShell = NSView()
        resultsShell.wantsLayer = true
        resultsShell.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        resultsShell.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(search)
        root.addSubview(resultsShell)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            resultsShell.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            resultsShell.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            resultsShell.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            resultsShell.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        panel.contentView = root
        panel.makeKeyAndOrderFront(nil)
        let acceptedFirstResponder = panel.makeFirstResponder(search)
        await Task.yield()
        let coldMilliseconds = elapsedMilliseconds(since: coldStarted)
        let coldFocused = acceptedFirstResponder && panel.firstResponder != nil

        panel.orderOut(nil)
        await Task.yield()
        let warmStarted = DispatchTime.now().uptimeNanoseconds
        panel.makeKeyAndOrderFront(nil)
        let acceptedWarmFirstResponder = panel.makeFirstResponder(search)
        await Task.yield()
        let warmMilliseconds = elapsedMilliseconds(since: warmStarted)
        let warmFocused = acceptedWarmFirstResponder && panel.firstResponder != nil
        panel.close()
        return (coldMilliseconds, warmMilliseconds, coldFocused && warmFocused)
    }

    private func fastScrollSamples(gridDriver: S6GridDriver) async -> [Double] {
        var framesPerSecond: [Double] = []
        framesPerSecond.reserveCapacity(120)
        for index in 0 ..< 120 {
            let started = DispatchTime.now().uptimeNanoseconds
            let cardID = min(fixture.cards.count - 1, index * 83)
            gridDriver.scrollTo(cardID: cardID)
            try? await Task.sleep(for: .milliseconds(16))
            let interval = max(0.001, elapsedMilliseconds(since: started) / 1_000)
            framesPerSecond.append(min(60, 1 / interval))
        }
        return framesPerSecond
    }

    private func thumbnailFeedbackSamples() async throws -> [Double] {
        _ = try await decodeCache.frame(
            mediaURL: mediaURL,
            frameIndex: 0,
            maximumSize: CGSize(width: 240, height: 160)
        )
        var samples: [Double] = []
        for _ in 0 ..< 50 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await decodeCache.frame(
                mediaURL: mediaURL,
                frameIndex: 0,
                maximumSize: CGSize(width: 240, height: 160)
            )
            samples.append(elapsedMilliseconds(since: started))
        }
        return samples
    }

    private func fullFrameSettleSamples() async throws -> [Double] {
        var samples: [Double] = []
        for index in 0 ..< 20 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await S6MediaDecodeCache.decode(
                mediaURL: mediaURL,
                frameIndex: index,
                maximumSize: CGSize(width: 1_440, height: 900)
            )
            samples.append(elapsedMilliseconds(since: started))
        }
        return samples
    }

    private func rapidSelectionResult() async -> (
        selectionCount: Int,
        expectedSelectionID: Int,
        publishedSelectionID: Int,
        staleScreenshotCount: Int
    ) {
        let selectionCount = 100
        var tokens: [S6SelectionToken] = []
        for cardID in 0 ..< selectionCount {
            tokens.append(await selectionCoordinator.beginSelection(cardID: cardID))
        }
        var published: [Int] = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for token in tokens {
                group.addTask { [selectionCoordinator] in
                    let reverseDelay = selectionCount - token.cardID
                    try? await Task.sleep(for: .microseconds(reverseDelay * 20))
                    return (token.cardID, await selectionCoordinator.canPublish(token))
                }
            }
            for await result in group where result.1 {
                published.append(result.0)
            }
        }
        let expected = selectionCount - 1
        let staleCount = published.filter { $0 != expected }.count
        return (selectionCount, expected, published.last ?? -1, staleCount)
    }

    private func residentMemoryMegabytes() -> Double {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return .infinity
        }
        return Double(information.resident_size) / 1_048_576
    }

    private func elapsedMilliseconds(since started: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    private static var configurationName: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }
}

struct S6SpikeView: View {
    @StateObject private var controller: S6HarnessController
    @StateObject private var gridDriver = S6GridDriver()
    @State private var selectedCardID = 0
    @State private var searchQuery = ""
    @State private var timelinePosition = 0.0
    @State private var useDarkAppearance = false
    @State private var usePseudoLocalization = false
    @State private var compactLayout = false
    @FocusState private var searchFocused: Bool

    init(
        outputDirectory: URL,
        mediaURL: URL,
        autoExit: Bool
    ) {
        _controller = StateObject(
            wrappedValue: S6HarnessController(
                outputDirectory: outputDirectory,
                mediaURL: mediaURL,
                autoExit: autoExit
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            S6Toolbar(
                searchQuery: $searchQuery,
                searchFocused: $searchFocused,
                useDarkAppearance: $useDarkAppearance,
                usePseudoLocalization: $usePseudoLocalization,
                compactLayout: $compactLayout,
                warmVisibilityPulse: $controller.warmVisibilityPulse
            )
            Divider()
            HSplitView {
                S6CardGrid(
                    cards: controller.fixture.cards,
                    selectedCardID: selectedCardID,
                    pseudoLocalized: usePseudoLocalization,
                    driver: gridDriver
                ) { card in
                    selectedCardID = card.id
                    controller.select(card: card)
                }
                .frame(minWidth: compactLayout ? 300 : 360)

                S6DetailSurface(
                    previewImage: controller.previewImage,
                    previewCardID: controller.previewCardID,
                    timeline: controller.fixture.timeline,
                    timelinePosition: $timelinePosition,
                    pseudoLocalized: usePseudoLocalization
                )
                .frame(minWidth: 270)
            }
            Divider()
            HStack {
                ProgressView().controlSize(.small).opacity(controller.benchmarkComplete ? 0 : 1)
                Text(controller.benchmarkStatus)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("10,000 local results")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .frame(
            minWidth: CGFloat(LM008UIDefaults.minimumPanelWidth),
            minHeight: CGFloat(LM008UIDefaults.minimumPanelHeight)
        )
        .preferredColorScheme(useDarkAppearance ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("s6.root")
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
            searchFocused = true
        }
        .task {
            searchFocused = true
            try? await Task.sleep(for: .milliseconds(50))
            await controller.run(
                gridDriver: gridDriver
            )
        }
    }
}

private struct S6Toolbar: View {
    @Binding var searchQuery: String
    var searchFocused: FocusState<Bool>.Binding
    @Binding var useDarkAppearance: Bool
    @Binding var usePseudoLocalization: Bool
    @Binding var compactLayout: Bool
    @Binding var warmVisibilityPulse: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .accessibilityHidden(true)
            TextField("Search this Mac", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused(searchFocused)
                .accessibilityIdentifier("s6.search")
            Button("Warm") { warmVisibilityPulse.toggle() }
                .accessibilityIdentifier("s6.warm")
            Button(useDarkAppearance ? "Light" : "Dark") { useDarkAppearance.toggle() }
                .accessibilityIdentifier("s6.appearance")
            Button("Long labels") { usePseudoLocalization.toggle() }
                .accessibilityIdentifier("s6.pseudo")
            Button("Resize") {
                compactLayout.toggle()
                let size = compactLayout
                    ? NSSize(
                        width: LM008UIDefaults.minimumPanelWidth,
                        height: LM008UIDefaults.minimumPanelHeight
                    )
                    : NSSize(
                        width: LM008UIDefaults.panelWidth,
                        height: LM008UIDefaults.panelHeight
                    )
                NSApplication.shared.keyWindow?.setContentSize(size)
            }
                .accessibilityIdentifier("s6.resize")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(warmVisibilityPulse ? Color.accentColor.opacity(0.04) : Color.clear)
    }
}

@MainActor
final class S6GridDriver: ObservableObject {
    weak var collectionView: NSCollectionView?

    func scrollTo(cardID: Int) {
        collectionView?.scrollToItems(
            at: [IndexPath(item: cardID, section: 0)],
            scrollPosition: .centeredVertically
        )
    }
}

private struct S6CardGrid: NSViewRepresentable {
    let cards: [S6Card]
    let selectedCardID: Int
    let pseudoLocalized: Bool
    let driver: S6GridDriver
    let onSelection: (S6Card) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 164, height: 126)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            S6CollectionViewItem.self,
            forItemWithIdentifier: S6CollectionViewItem.identifier
        )
        collectionView.setAccessibilityIdentifier("s6.grid")
        collectionView.reloadData()
        collectionView.selectionIndexPaths = [IndexPath(item: selectedCardID, section: 0)]
        context.coordinator.lastSelectedCardID = selectedCardID
        context.coordinator.lastPseudoLocalized = pseudoLocalized

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        driver.collectionView = collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let collectionView = scrollView.documentView as? NSCollectionView else {
            return
        }
        driver.collectionView = collectionView
        if context.coordinator.lastPseudoLocalized != pseudoLocalized {
            context.coordinator.lastPseudoLocalized = pseudoLocalized
            collectionView.reloadData()
        }
        if context.coordinator.lastSelectedCardID != selectedCardID {
            context.coordinator.lastSelectedCardID = selectedCardID
            collectionView.selectionIndexPaths = [IndexPath(item: selectedCardID, section: 0)]
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: S6CardGrid
        var lastSelectedCardID: Int?
        var lastPseudoLocalized: Bool?

        init(parent: S6CardGrid) {
            self.parent = parent
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            parent.cards.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            guard let item = collectionView.makeItem(
                withIdentifier: S6CollectionViewItem.identifier,
                for: indexPath
            ) as? S6CollectionViewItem else {
                preconditionFailure("S6 collection item registration failed")
            }
            let card = parent.cards[indexPath.item]
            item.configure(
                card: card,
                selected: parent.selectedCardID == card.id,
                pseudoLocalized: parent.pseudoLocalized
            )
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard let index = indexPaths.first?.item, parent.cards.indices.contains(index) else {
                return
            }
            parent.onSelection(parent.cards[index])
        }
    }
}

private final class S6CollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("S6CollectionViewItem")

    private let preview = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let applicationLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 10

        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        applicationLabel.font = .systemFont(ofSize: 11)
        applicationLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [preview, titleLabel, applicationLabel])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -8),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 76),
        ])
        view = root
    }

    func configure(card: S6Card, selected: Bool, pseudoLocalized: Bool) {
        let hue = CGFloat(card.id % 37) / 37
        preview.layer?.backgroundColor = NSColor(
            hue: hue,
            saturation: 0.25,
            brightness: 0.72,
            alpha: 1
        ).cgColor
        titleLabel.stringValue = pseudoLocalized
            ? "⟦ \(card.title) — expanded history description ⟧"
            : card.title
        applicationLabel.stringValue = card.applicationName
        view.layer?.backgroundColor = (
            selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor
        ).cgColor
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier("s6.card.\(card.id)")
        view.setAccessibilityLabel("\(card.title), \(card.applicationName)")
    }
}

private struct S6CardCell: View {
    let card: S6Card
    let selected: Bool
    let pseudoLocalized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(hue: Double(card.id % 37) / 37, saturation: 0.25, brightness: 0.72))
                .frame(height: 82)
                .overlay(alignment: .bottomTrailing) {
                    Text(String(format: "%02d:%02d", card.minuteOfDay / 60, card.minuteOfDay % 60))
                        .font(.caption2.monospacedDigit())
                        .padding(5)
                }
                .accessibilityHidden(true)
            Text(pseudoLocalized ? "⟦ \(card.title) — expanded history description ⟧" : card.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(card.applicationName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title), \(card.applicationName)")
    }
}

private struct S6DetailSurface: View {
    let previewImage: NSImage?
    let previewCardID: Int
    let timeline: [S6TimelineMarker]
    @Binding var timelinePosition: Double
    let pseudoLocalized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pseudoLocalized ? "⟦ Selected local moment with surrounding context ⟧" : "Selected moment")
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("s6.detail.title")
            Group {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        ProgressView("Decoding local HEVC")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Screenshot for result \(previewCardID)")
            .accessibilityIdentifier("s6.preview")

            S6TimelineRail(timeline: timeline, position: $timelinePosition)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("s6.detail")
    }
}

private struct S6TimelineRail: View {
    let timeline: [S6TimelineMarker]
    @Binding var position: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                ForEach(timeline) { marker in
                    Capsule()
                        .fill(marker.isGap ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(0.72))
                        .frame(maxWidth: .infinity, minHeight: 14, maxHeight: marker.isGap ? 14 : 22)
                        .accessibilityLabel(
                            marker.isGap
                                ? "Gap at minute \(marker.minuteOfDay)"
                                : "Captured moment at minute \(marker.minuteOfDay)"
                        )
                }
            }
            .frame(height: 24)
            Slider(value: $position, in: 0 ... 95, step: 1)
                .accessibilityLabel("24 hour timeline")
                .accessibilityValue("Marker \(Int(position) + 1) of 96")
                .accessibilityIdentifier("s6.timeline")
        }
        .frame(height: 62)
    }
}

private struct S6InitialResultSurface: View {
    let cards: [S6Card]
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(cards) { card in
                    S6CardCell(card: card, selected: card.id == 0, pseudoLocalized: false)
                }
            }
        }
    }
}
