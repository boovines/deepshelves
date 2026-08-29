import AppKit
import CoreGraphics
import MemoryDesignSystem
import MemorySearch
import SwiftUI

struct SearchMomentTimelineRail: View {
    @ObservedObject var model: MomentTimelineSessionModel
    @State private var showsAccessibilityList = false

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                ProgressView("Loading surrounding moments…")
                    .controlSize(.small)
                    .accessibilityIdentifier("timeline.loading")
            case .failure:
                Label("Surrounding timeline unavailable", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("timeline.recovery")
            case .ready(let projection):
                readyRail(projection)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(MemoryColorToken.surfaceControl.color.opacity(0.45))
        .accessibilityIdentifier("timeline.rail")
    }

    private func readyRail(_ projection: MomentTimelineProjection) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(intervalLabel(projection.interval))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                Spacer()
                Picker("Timeline zoom", selection: zoomBinding) {
                    Text("Day").tag(MomentTimelineZoomLevel.calendarDay)
                    Text("6 hours").tag(MomentTimelineZoomLevel.sixHours)
                    Text("1 hour").tag(MomentTimelineZoomLevel.oneHour)
                    Text("15 minutes").tag(MomentTimelineZoomLevel.fifteenMinutes)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .accessibilityIdentifier("timeline.zoom")

                Button("Timeline accessibility list", systemImage: "list.bullet") {
                    showsAccessibilityList.toggle()
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .popover(isPresented: $showsAccessibilityList, arrowEdge: .bottom) {
                    accessibilityList(projection)
                }
                .accessibilityIdentifier("timeline.accessibilityListButton")
            }

            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MemoryColorToken.borderDefault.color.opacity(0.22))
                        .frame(height: 18)

                    ForEach(Array(projection.gaps.enumerated()), id: \.offset) { _, gap in
                        MomentTimelineGapPatternView(pattern: gap.pattern)
                            .frame(
                                width: max(2, (gap.normalizedEnd - gap.normalizedStart) * width),
                                height: 18
                            )
                            .offset(x: gap.normalizedStart * width)
                            .accessibilityHidden(true)
                    }

                    ForEach(Array(projection.transitions.enumerated()), id: \.offset) {
                        _, transition in
                        Rectangle()
                            .fill(MemoryColorToken.textSecondary.color)
                            .frame(width: 1, height: 24)
                            .offset(x: transition.normalizedPosition * width)
                            .accessibilityHidden(true)
                    }

                    ForEach(projection.moments, id: \.result.frameID) { moment in
                        Circle()
                            .fill(
                                moment.result.frameID == model.scrubbedResult?.frameID
                                    ? MemoryColorToken.accent.color
                                    : MemoryColorToken.textSecondary.color.opacity(0.7)
                            )
                            .frame(width: 8, height: 8)
                            .offset(x: moment.normalizedPosition * max(0, width - 8))
                            .accessibilityHidden(true)
                    }

                    Slider(value: scrubBinding, in: 0...1)
                        .tint(.clear)
                        .opacity(0.02)
                        .accessibilityLabel("Surrounding moments timeline")
                        .accessibilityValue(selectedAccessibilityValue)
                        .accessibilityHint("Use arrow keys to move between captured moments")
                        .accessibilityIdentifier("timeline.scrubber")

                    scrubPreview
                        .frame(width: 52, height: 34)
                        .offset(
                            x: min(
                                max(0, model.normalizedPosition * width - 26),
                                max(0, width - 52)
                            ),
                            y: -8
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 42)
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .left: model.step(.previous)
                case .right: model.step(.next)
                default: break
                }
            }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.step(.next)
                case .decrement: model.step(.previous)
                @unknown default: break
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var scrubPreview: some View {
        switch model.preview {
        case .ready(let response):
            if let image = Self.image(response.raster) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(MemoryColorToken.borderDefault.color, lineWidth: 1)
                    }
                    .accessibilityLabel("Low-resolution scrub preview")
            }
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Loading low-resolution scrub preview")
        case .idle, .unavailable:
            EmptyView()
        }
    }

    private func accessibilityList(_ projection: MomentTimelineProjection) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(projection.accessibilityItems) { item in
                    if let frameID = item.frameID,
                        let moment = projection.moments.first(where: {
                            $0.result.frameID == frameID
                        })
                    {
                        Button(item.label) {
                            model.scrub(to: moment.normalizedPosition)
                            showsAccessibilityList = false
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Select this captured moment")
                    } else {
                        Text(item.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 360, height: 280)
        .accessibilityLabel("Timeline accessibility list")
        .accessibilityIdentifier("timeline.accessibilityList")
    }

    private var zoomBinding: Binding<MomentTimelineZoomLevel> {
        Binding(
            get: { model.zoom },
            set: { zoom in Task { await model.setZoom(zoom) } }
        )
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { model.normalizedPosition },
            set: { model.scrub(to: $0) }
        )
    }

    private var selectedAccessibilityValue: String {
        guard let result = model.scrubbedResult else { return "No captured moment selected" }
        return "\(result.capturedAt.formatted(date: .omitted, time: .standard)), "
            + result.foreground.applicationName
    }

    private func intervalLabel(_ interval: DateInterval) -> String {
        let start = interval.start.formatted(date: .abbreviated, time: .shortened)
        let end = interval.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private static func image(_ raster: SearchThumbnailRaster) -> NSImage? {
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
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: raster.width, height: raster.height)
        )
    }
}

private struct MomentTimelineGapPatternView: View {
    let pattern: MomentTimelineGapPattern

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(MemoryColorToken.textSecondary.color.opacity(0.10))
            )
            let stroke = GraphicsContext.Shading.color(
                MemoryColorToken.textSecondary.color.opacity(0.48)
            )
            switch pattern {
            case .userControl:
                for x in stride(from: -size.height, through: size.width, by: 6) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    context.stroke(path, with: stroke, lineWidth: 1)
                }
            case .inactivity:
                for x in stride(from: 3.0, through: size.width, by: 7) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: size.height / 2 - 1, width: 2, height: 2)),
                        with: stroke
                    )
                }
            case .privacy:
                for x in stride(from: 0.0, through: size.width, by: 6) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: stroke, lineWidth: 1)
                }
            case .unavailable:
                for x in stride(from: -size.height, through: size.width, by: 7) {
                    var descending = Path()
                    descending.move(to: CGPoint(x: x, y: 0))
                    descending.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    context.stroke(descending, with: stroke, lineWidth: 1)
                    var ascending = Path()
                    ascending.move(to: CGPoint(x: x, y: size.height))
                    ascending.addLine(to: CGPoint(x: x + size.height, y: 0))
                    context.stroke(ascending, with: stroke, lineWidth: 1)
                }
            }
        }
        .clipShape(Capsule())
    }
}
