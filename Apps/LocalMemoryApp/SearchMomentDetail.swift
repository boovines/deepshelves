import AppKit
import CoreGraphics
import MemoryContracts
import MemorySearch
import SwiftUI
import UniformTypeIdentifiers

struct SearchMomentDetailView: View {
    let result: SearchResult
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var searchModel: SearchSessionModel
    let exportProvider: MomentExportProvider?

    @StateObject private var model: MomentDetailSessionModel
    @StateObject private var timelineModel: MomentTimelineSessionModel
    @State private var transform = MomentCanvasTransform.identity
    @GestureState private var transientMagnification = 1.0
    @GestureState private var transientDrag = CGSize.zero
    @State private var exportStatus: String?
    @State private var exportPackageRoot: URL?
    @State private var showsForgetConfirmation = false
    @State private var showsSourceDetails = false
    @State private var showsDiagnostics = false
    @State private var showsInspector = false
    @State private var revisitStatus: String?
    @State private var rangeStart: Date
    @State private var rangeEnd: Date
    @StateObject private var forgetModel: ForgetSessionModel

    init(
        result: SearchResult,
        navigationModel: MainNavigationViewModel,
        searchModel: SearchSessionModel,
        repository: MomentDetailRepository?,
        exportProvider: MomentExportProvider?,
        timelineLoader: MomentTimelinePageLoader?,
        thumbnailRepository: SearchThumbnailRepository?
    ) {
        self.result = result
        self.navigationModel = navigationModel
        self.searchModel = searchModel
        self.exportProvider = exportProvider
        let repository =
            repository
            ?? MomentDetailRepository(
                capacityBytes: 1,
                loader: MomentDetailLoader { _ in
                    throw MomentDetailError.sourceUnavailable
                }
            )
        _model = StateObject(wrappedValue: MomentDetailSessionModel(repository: repository))
        let timelineLoader =
            timelineLoader
            ?? MomentTimelinePageLoader { _ in
                throw MomentTimelineError.unavailable
            }
        _timelineModel = StateObject(
            wrappedValue: MomentTimelineSessionModel(
                loader: timelineLoader,
                thumbnailRepository: thumbnailRepository
            )
        )
        _rangeStart = State(initialValue: result.capturedAt.addingTimeInterval(-5 * 60))
        _rangeEnd = State(initialValue: result.capturedAt.addingTimeInterval(5 * 60))
        let unavailableProvider = MomentForgetProvider { _ in
            throw SearchMomentForgetPresentationError.unavailable
        }
        _forgetModel = StateObject(
            wrappedValue: ForgetSessionModel(
                provider: searchModel.momentForgetProvider ?? unavailableProvider
            )
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            Group {
                switch model.state {
                case .idle, .loading:
                    ProgressView("Loading exact source frame…")
                        .accessibilityIdentifier("detail.loading")
                case .ready(let frame):
                    detail(frame)
                case .failure(_, let reason):
                    recovery(reason)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: result.frameID) {
            await timelineModel.load(around: result)
        }
        .task(id: displayedResult.frameID) {
            transform = .identity
            await model.select(displayedResult)
        }
        .onDisappear {
            timelineModel.clear()
            Task { await model.clear() }
        }
        .sheet(isPresented: $showsForgetConfirmation) {
            ForgetConfirmationFlow(
                model: forgetModel,
                onHidden: hideForgottenResults,
                onDismiss: { showsForgetConfirmation = false }
            )
        }
        .popover(isPresented: $showsInspector, arrowEdge: .top) {
            inspector
                .frame(width: 380, height: 520)
                .padding(8)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shellForgetMoment)) { _ in
            beginForget(.moment(displayedResult.frameID))
        }
        .accessibilityIdentifier("detail.root")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button("Back", systemImage: "chevron.left") { navigationModel.goBack() }
                .accessibilityIdentifier("detail.back")
                .buttonStyle(.borderless)
            Text(displayedResult.foreground.applicationName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                showsInspector.toggle()
            } label: {
                Label("Moment details", systemImage: "info.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Moment details and source")
            .accessibilityIdentifier("detail.info")
            Menu {
                Button("Export Moment…", systemImage: "square.and.arrow.up") {
                    exportMoment()
                }
                .disabled(exportProvider == nil)
                Button("Revisit", systemImage: "arrow.up.forward.app") {
                    revisitMoment()
                }
                .disabled(searchModel.momentRevisitProvider == nil)
                Button("Forget Moment…", systemImage: "trash", role: .destructive) {
                    beginForget(.moment(displayedResult.frameID))
                }
                .disabled(searchModel.momentForgetProvider == nil)
            } label: {
                Label("More moment actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("detail.actions")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    private func detail(_ frame: MomentDetailFrame) -> some View {
        VStack(spacing: 12) {
            ZStack {
                GeometryReader { geometry in
                    let currentScale = min(
                        8,
                        max(1, transform.scale * transientMagnification)
                    )
                    MomentDetailCanvasImage(frame: frame)
                        .scaleEffect(currentScale)
                        .offset(
                            x: transform.offsetX + transientDrag.width,
                            y: transform.offsetY + transientDrag.height
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(magnificationGesture)
                        .simultaneousGesture(dragGesture(size: geometry.size))
                        .accessibilityLabel("Exact captured foreground-window frame")
                        .accessibilityIdentifier("detail.canvas")
                }
                .clipped()
                .background(Color.black.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                HStack {
                    canvasStepButton(.previous, systemImage: "chevron.left")
                    Spacer()
                    canvasStepButton(.next, systemImage: "chevron.right")
                }
                .padding(.horizontal, 16)

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Button {
                            showsInspector = true
                        } label: {
                            Label(
                                displayedResult.capturedAt.formatted(
                                    date: .abbreviated, time: .shortened),
                                systemImage: "calendar.badge.clock"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("Show moment details")
                        .accessibilityIdentifier("detail.timestamp")

                        Spacer()

                        Button {
                            transform = .identity
                        } label: {
                            Label(
                                "Fit screenshot", systemImage: "arrow.down.right.and.arrow.up.left"
                            )
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(transform == .identity)
                        .help("Fit screenshot")
                        .accessibilityIdentifier("detail.fit")
                    }
                    .padding(16)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(canvasChrome.accessibilityLabel)
            SearchMomentTimelineRail(model: timelineModel)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func canvasStepButton(
        _ direction: MomentDetailStepDirection,
        systemImage: String
    ) -> some View {
        Button {
            step(direction)
        } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 52)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(adjacent(direction) == nil)
        .help(direction == .previous ? "Previous moment" : "Next moment")
        .accessibilityLabel(direction == .previous ? "Previous moment" : "Next moment")
        .accessibilityIdentifier(direction == .previous ? "detail.previous" : "detail.next")
    }

    private var canvasChrome: MomentCanvasChromeProjection {
        MomentCanvasChromeProjection(
            applicationName: displayedResult.foreground.applicationName,
            timestamp: displayedResult.capturedAt.formatted(date: .abbreviated, time: .shortened),
            canStepPrevious: adjacent(.previous) != nil,
            canStepNext: adjacent(.next) != nil,
            isTransformed: transform != .identity
        )
    }

    private var inspector: some View {
        Form {
            Section("Moment") {
                LabeledContent("Time", value: displayedResult.capturedAt.formatted())
                LabeledContent("Application", value: displayedResult.foreground.applicationName)
                if let title = displayedResult.foreground.windowTitle {
                    LabeledContent("Window", value: title)
                }
                if let host = displayedResult.browser?.origin.host {
                    LabeledContent("Site", value: host)
                }
            }
            Section {
                DisclosureGroup(
                    isExpanded: $showsSourceDetails,
                    content: {
                        let disclosure = SearchEvidenceDisclosureProjection(
                            evidence: displayedResult.evidence
                        )
                        ForEach(Array(disclosure.lines.enumerated()), id: \.offset) { _, line in
                            LabeledContent(line.sourceLabel, value: line.displayText)
                        }
                    },
                    label: {
                        let disclosure = SearchEvidenceDisclosureProjection(
                            evidence: displayedResult.evidence
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Source details")
                            Text(disclosure.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                )
                .accessibilityLabel(
                    SearchEvidenceDisclosureProjection(evidence: displayedResult.evidence)
                        .accessibilityLabel
                )
                .accessibilityIdentifier("detail.sourceDisclosure")
            }
            if searchModel.diagnosticsEnabled {
                Section {
                    DisclosureGroup("Search diagnostics", isExpanded: $showsDiagnostics) {
                        Text("Diagnostics are available only in an explicitly enabled session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("detail.diagnosticsDisclosure")
                }
            }
            if let exportStatus {
                Section("Export") {
                    Text(exportStatus)
                    if let exportPackageRoot {
                        Button("Show Export in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([exportPackageRoot])
                        }
                        .accessibilityIdentifier("detail.revealExport")
                    }
                }
            }
            if let revisitStatus {
                Section("Revisit") {
                    Text(revisitStatus)
                }
            }
            Section("Forget range") {
                DatePicker("From", selection: $rangeStart)
                DatePicker("Until", selection: $rangeEnd)
                Button("Forget Selected Range…", role: .destructive) {
                    guard rangeStart < rangeEnd else { return }
                    beginForget(
                        .range(DateInterval(start: rangeStart, end: rangeEnd))
                    )
                }
                .disabled(searchModel.momentForgetProvider == nil || rangeStart >= rangeEnd)
                .accessibilityIdentifier("detail.forgetRange")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("detail.inspector")
    }

    private func recovery(_ reason: MomentDetailError) -> some View {
        ContentUnavailableView {
            Label("Original evidence unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(recoveryMessage(reason))
        } actions: {
            Button("Try Again") { Task { await model.retry() } }
                .accessibilityIdentifier("detail.retry")
        }
        .accessibilityIdentifier("detail.recovery")
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($transientMagnification) { value, state, _ in state = value }
            .onEnded { value in transform = transform.zoomed(to: transform.scale * value) }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .updating($transientDrag) { value, state, _ in
                if transform.scale > 1 { state = value.translation }
            }
            .onEnded { value in
                transform = transform.panned(
                    byX: value.translation.width,
                    y: value.translation.height,
                    viewportWidth: size.width,
                    viewportHeight: size.height
                )
            }
    }

    private func adjacent(_ direction: MomentDetailStepDirection) -> SearchResult? {
        if case .ready(let projection) = timelineModel.phase,
            let current = timelineModel.scrubbedResult ?? timelineModel.settledResult,
            let adjacent = projection.adjacentMoment(to: current.frameID, direction: direction)
        {
            return adjacent.result
        }
        return MomentDetailSequence.adjacent(
            to: displayedResult.frameID,
            direction: direction,
            in: searchModel.results
        )
    }

    private func step(_ direction: MomentDetailStepDirection) {
        if case .ready = timelineModel.phase {
            timelineModel.step(direction)
            return
        }
        guard let result = adjacent(direction) else { return }
        navigationModel.select(momentID: result.frameID)
    }

    private func revisitMoment() {
        guard let provider = searchModel.momentRevisitProvider else { return }
        revisitStatus = "Opening approved source…"
        Task {
            do {
                let plan = try await provider.revisit(displayedResult)
                revisitStatus =
                    plan.approvedURL == nil
                    ? "Opened the approved application; captured state was not restored."
                    : "Opened the approved application and address; captured state was not restored."
                showsInspector = true
            } catch {
                revisitStatus =
                    "Revisit is unavailable because the current source or policy changed."
                showsInspector = true
            }
        }
    }

    private func exportMoment() {
        guard let exportProvider else { return }
        exportStatus = "Preparing verified evidence package…"
        exportPackageRoot = nil
        Task {
            do {
                let payload = try await exportProvider.payload(for: displayedResult)
                if let packageRoot = payload.packageRoot {
                    exportPackageRoot = packageRoot
                    exportStatus =
                        "Exported a self-describing package with verified original evidence."
                    return
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = payload.suggestedFilename
                panel.allowedContentTypes = [.heic]
                guard panel.runModal() == .OK, let destination = panel.url else {
                    exportStatus = nil
                    return
                }
                try payload.heicData.write(to: destination, options: [.atomic])
                exportStatus = "Exported verified original HEIC."
            } catch {
                exportPackageRoot = nil
                exportStatus = "Export failed; the archive was not changed."
            }
        }
    }

    private func recoveryMessage(_ reason: MomentDetailError) -> String {
        switch reason {
        case .integrityMismatch:
            "The source file no longer matches its recorded integrity hash."
        case .manifestMismatch:
            "The source manifest no longer identifies this exact frame."
        case .corruptMedia, .invalidRaster:
            "The verified source could not be decoded."
        case .sourceUnavailable:
            "The exact source is missing, suppressed, or no longer ready."
        case .exportFailed:
            "The verified original could not be exported."
        }
    }

    private var displayedResult: SearchResult {
        timelineModel.settledResult ?? result
    }

    private func beginForget(_ target: ForgetTarget) {
        guard searchModel.momentForgetProvider != nil else { return }
        forgetModel.begin(target)
        showsForgetConfirmation = true
    }

    private func hideForgottenResults(_ frameIDs: Set<UUID>) {
        searchModel.hideResults(frameIDs: frameIDs)
        if frameIDs.contains(displayedResult.frameID) {
            navigationModel.goBack()
        }
    }

}

private enum SearchMomentForgetPresentationError: Error {
    case unavailable
}

@MainActor
private struct MomentDetailCanvasImage: NSViewRepresentable {
    let frame: MomentDetailFrame

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Exact captured foreground-window frame")
        imageView.setAccessibilityIdentifier("detail.canvas")
        update(imageView, coordinator: context.coordinator)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        update(imageView, coordinator: context.coordinator)
    }

    private func update(_ imageView: NSImageView, coordinator: Coordinator) {
        guard coordinator.identity != frame.identity else { return }
        coordinator.identity = frame.identity
        imageView.image = Self.image(frame.raster)
    }

    private static func image(_ raster: MomentDetailRaster) -> NSImage {
        let data = Data(raster.rgba8) as CFData
        guard let provider = CGDataProvider(data: data),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: raster.width,
                height: raster.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: raster.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.last.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            return NSImage()
        }
        return NSImage(cgImage: image, size: NSSize(width: raster.width, height: raster.height))
    }

    final class Coordinator {
        var identity: MomentDetailIdentity?
    }
}
