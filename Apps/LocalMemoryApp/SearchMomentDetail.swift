import AppKit
import CoreGraphics
import MemoryContracts
import MemorySearch
import SwiftUI
import UniformTypeIdentifiers

struct SearchMomentDetailView: View {
    let result: SearchResult
    let results: [SearchResult]
    @ObservedObject var navigationModel: MainNavigationViewModel
    let exportProvider: MomentExportProvider?

    @StateObject private var model: MomentDetailSessionModel
    @StateObject private var timelineModel: MomentTimelineSessionModel
    @State private var transform = MomentCanvasTransform.identity
    @GestureState private var transientMagnification = 1.0
    @GestureState private var transientDrag = CGSize.zero
    @State private var exportStatus: String?

    init(
        result: SearchResult,
        results: [SearchResult],
        navigationModel: MainNavigationViewModel,
        repository: MomentDetailRepository?,
        exportProvider: MomentExportProvider?,
        timelineLoader: MomentTimelinePageLoader?,
        thumbnailRepository: SearchThumbnailRepository?
    ) {
        self.result = result
        self.results = results
        self.navigationModel = navigationModel
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
        .accessibilityIdentifier("detail.root")
    }

    private var toolbar: some View {
        HStack {
            Button("Back", systemImage: "chevron.left") { navigationModel.goBack() }
                .accessibilityIdentifier("detail.back")
            Divider().frame(height: 18)
            Button("Previous", systemImage: "arrow.left") { step(.previous) }
                .disabled(adjacent(.previous) == nil)
                .accessibilityIdentifier("detail.previous")
            Button("Next", systemImage: "arrow.right") { step(.next) }
                .disabled(adjacent(.next) == nil)
                .accessibilityIdentifier("detail.next")
            Spacer()
            Button("Actual Size") { transform = .identity }
                .disabled(transform == .identity)
            Button("Export Moment…", systemImage: "square.and.arrow.up") {
                exportMoment()
            }
            .disabled(exportProvider == nil)
            .accessibilityIdentifier("detail.export")
        }
    }

    private func detail(_ frame: MomentDetailFrame) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
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

                Divider()
                inspector
                    .frame(width: 260)
            }
            Divider()
            SearchMomentTimelineRail(model: timelineModel)
        }
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
            Section("Evidence") {
                ForEach(Array(displayedResult.evidence.enumerated()), id: \.offset) { _, evidence in
                    let projection = SearchEvidenceLineProjection(evidence: evidence)
                    LabeledContent(projection.sourceLabel, value: projection.displayText)
                }
            }
            if let exportStatus {
                Section("Export") { Text(exportStatus) }
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
        MomentDetailSequence.adjacent(
            to: displayedResult.frameID,
            direction: direction,
            in: results
        )
    }

    private func step(_ direction: MomentDetailStepDirection) {
        guard let result = adjacent(direction) else { return }
        navigationModel.select(momentID: result.frameID)
    }

    private func exportMoment() {
        guard let exportProvider else { return }
        exportStatus = "Preparing verified original…"
        Task {
            do {
                let payload = try await exportProvider.payload(for: displayedResult)
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
