import AppKit
import CoreGraphics
import MemoryContracts
import MemorySearch
import SwiftUI

@MainActor
private final class SearchThumbnailViewModel: ObservableObject {
    @Published private(set) var revision = 0

    private let repository: SearchThumbnailRepository?
    private var rasters: [UUID: SearchThumbnailRaster] = [:]
    private var identities: [UUID: SearchThumbnailIdentity] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(repository: SearchThumbnailRepository?) {
        self.repository = repository
    }

    func request(_ result: SearchResult) {
        guard let repository, let identity = SearchThumbnailIdentity(result: result) else {
            return
        }
        if identities[result.frameID] == identity,
            rasters[result.frameID] != nil || tasks[result.frameID] != nil
        {
            return
        }
        identities[result.frameID] = identity
        rasters[result.frameID] = nil
        tasks[result.frameID]?.cancel()
        tasks[result.frameID] = Task { [weak self] in
            defer { self?.tasks[result.frameID] = nil }
            guard let response = try? await repository.thumbnail(for: result),
                !Task.isCancelled,
                let self,
                self.identities[result.frameID] == response.identity
            else {
                return
            }
            self.rasters[result.frameID] = response.raster
            self.revision += 1
        }
    }

    func image(frameID: UUID) -> NSImage? {
        guard let raster = rasters[frameID] else { return nil }
        return Self.image(raster: raster)
    }

    func retain(frameIDs: Set<UUID>) {
        for frameID in Set(tasks.keys).subtracting(frameIDs) {
            tasks.removeValue(forKey: frameID)?.cancel()
            identities.removeValue(forKey: frameID)
            rasters.removeValue(forKey: frameID)
        }
    }

    private static func image(raster: SearchThumbnailRaster) -> NSImage? {
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

struct SharedSearchResultsView: View {
    @ObservedObject var searchModel: SearchSessionModel
    @ObservedObject var navigationModel: MainNavigationViewModel
    @ObservedObject var filterModel: SearchFilterSessionModel
    let surface: SearchResultSurface
    let indexingBacklog: Int
    @StateObject private var thumbnailModel: SearchThumbnailViewModel

    init(
        searchModel: SearchSessionModel,
        navigationModel: MainNavigationViewModel,
        filterModel: SearchFilterSessionModel,
        indexingBacklog: Int,
        surface: SearchResultSurface
    ) {
        self.searchModel = searchModel
        self.navigationModel = navigationModel
        self.filterModel = filterModel
        self.surface = surface
        self.indexingBacklog = indexingBacklog
        _thumbnailModel = StateObject(
            wrappedValue: SearchThumbnailViewModel(
                repository: searchModel.thumbnailRepository
            )
        )
    }

    private var archiveHasSearchableContent: Bool {
        !filterModel.catalog.applications.isEmpty || !searchModel.results.isEmpty
    }

    private var contentState: SearchResultGridContentState {
        SearchResultGridProjection.contentState(
            phase: searchModel.phase,
            archiveHasSearchableContent: archiveHasSearchableContent,
            activeFilterLabels: filterModel.tokens.map(\.label),
            indexingBacklog: indexingBacklog
        )
    }

    var body: some View {
        Group {
            switch contentState {
            case .emptyArchive:
                ContentUnavailableView(
                    "Your screen memory will appear here after recording begins.",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Only approved foreground-window moments are indexed.")
                )
                .accessibilityIdentifier("search.emptyArchive")
            case .emptyQuery:
                ContentUnavailableView(
                    "Search your local memory",
                    systemImage: "magnifyingglass",
                    description: Text("Enter text or choose an approved app, site, or date filter.")
                )
            case .loading(let query):
                Text("Searching for “\(query)” locally…")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("search.loading")
            case .noResults(let query, let activeFilterLabels, let backlog):
                noResults(query: query, filters: activeFilterLabels, backlog: backlog)
            case .results(_, let backlog):
                results(backlog: backlog)
            case .addingVisualMatches(_, let backlog):
                results(backlog: backlog, isAddingVisualMatches: true)
            case .failure(_, let diagnosticCode):
                VStack(spacing: 8) {
                    ContentUnavailableView(
                        "Search unavailable",
                        systemImage: "exclamationmark.magnifyingglass",
                        description: Text("Your archive was not changed.")
                    )
                    Text("Diagnostic code: \(diagnosticCode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("search.errorCode")
                }
                .accessibilityIdentifier("search.error")
            }
        }
        .onChange(of: searchModel.results.map(\.frameID)) { _, frameIDs in
            thumbnailModel.retain(frameIDs: Set(frameIDs))
        }
    }

    @ViewBuilder
    private func noResults(query: String, filters: [String], backlog: Int) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView.search(text: query)
                .accessibilityIdentifier("search.empty")
            if !filters.isEmpty {
                Text("Active filters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(filterModel.tokens) { token in
                        Button("Remove \(token.label)") {
                            filterModel.removeFilter(id: token.id)
                        }
                        .controlSize(.small)
                    }
                }
            }
            if backlog > 0 {
                Text("Still indexing \(backlog) moments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func results(backlog: Int, isAddingVisualMatches: Bool = false) -> some View {
        VStack(spacing: 12) {
            if isAddingVisualMatches {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Adding visual matches · \(backlog) moments remaining")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("search.indexingBacklog")
            }
            SearchResultCollectionView(
                results: searchModel.results,
                cards: SearchResultGridProjection.cards(
                    from: searchModel.results,
                    diagnosticsEnabled: searchModel.diagnosticsEnabled
                ),
                selectedFrameID: navigationModel.snapshot.selectedMomentID,
                surface: surface,
                thumbnailModel: thumbnailModel,
                indexingBacklog: backlog,
                hasNextPage: searchModel.nextCursor != nil,
                onOpen: { result in
                    navigationModel.select(section: .search)
                    navigationModel.select(momentID: result.frameID)
                },
                onLoadMore: {
                    Task { await searchModel.loadNextPage() }
                }
            )
            if searchModel.isLoadingNextPage {
                ProgressView("Loading more results…")
                    .controlSize(.small)
                    .accessibilityIdentifier("search.loadingNextPage")
            } else if let code = searchModel.paginationFailureDiagnosticCode {
                HStack {
                    Text("More results could not be loaded. \(code)")
                    Button("Try again") {
                        Task { await searchModel.loadNextPage() }
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("search.paginationFailure")
            }
        }
    }
}

@MainActor
private struct SearchResultCollectionView: NSViewRepresentable {
    let results: [SearchResult]
    let cards: [SearchResultCardProjection]
    let selectedFrameID: UUID?
    let surface: SearchResultSurface
    @ObservedObject var thumbnailModel: SearchThumbnailViewModel
    let indexingBacklog: Int
    let hasNextPage: Bool
    let onOpen: (SearchResult) -> Void
    let onLoadMore: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 20, right: 8)

        let collectionView = SearchResultNSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            SearchResultCollectionItem.self,
            forItemWithIdentifier: SearchResultCollectionItem.identifier
        )
        collectionView.setAccessibilityIdentifier("search.resultGrid")
        collectionView.setAccessibilityLabel("Search result grid")
        context.coordinator.collectionView = collectionView
        collectionView.onActivate = context.coordinator.activateSelection

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.updateLayout(collectionView, width: 760)
        collectionView.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let collectionView = scrollView.documentView as? SearchResultNSCollectionView else {
            return
        }
        context.coordinator.updateLayout(collectionView, width: scrollView.bounds.width)
        let frameIDs = results.map(\.frameID)
        if context.coordinator.lastFrameIDs != frameIDs {
            context.coordinator.lastFrameIDs = frameIDs
            collectionView.reloadData()
        } else if context.coordinator.lastThumbnailRevision != thumbnailModel.revision {
            context.coordinator.lastThumbnailRevision = thumbnailModel.revision
            collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems())
        }
        if let selectedFrameID,
            let index = results.firstIndex(where: { $0.frameID == selectedFrameID })
        {
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else {
            collectionView.selectionIndexPaths = []
        }
        context.coordinator.announceResultChange(on: collectionView)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: SearchResultCollectionView
        var lastFrameIDs: [UUID] = []
        var lastThumbnailRevision = -1
        weak var collectionView: NSCollectionView?
        private var lastAnnouncedCount = 0

        init(parent: SearchResultCollectionView) {
            self.parent = parent
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            parent.results.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            guard parent.results.indices.contains(indexPath.item),
                parent.cards.indices.contains(indexPath.item),
                let item = collectionView.makeItem(
                    withIdentifier: SearchResultCollectionItem.identifier,
                    for: indexPath
                ) as? SearchResultCollectionItem
            else {
                return NSCollectionViewItem()
            }
            let result = parent.results[indexPath.item]
            let card = parent.cards[indexPath.item]
            item.configure(
                card: card,
                image: parent.thumbnailModel.image(frameID: result.frameID),
                selected: parent.selectedFrameID == result.frameID,
                accessibilityIdentifier: parent.surface.accessibilityIdentifier(for: result)
            )
            if indexPath.item >= max(0, parent.results.count - 10), parent.hasNextPage {
                parent.onLoadMore()
            }
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard parent.results.indices.contains(indexPath.item) else { return }
            parent.thumbnailModel.request(parent.results[indexPath.item])
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            activateSelection()
        }

        func activateSelection() {
            guard let index = collectionView?.selectionIndexPaths.first?.item,
                parent.results.indices.contains(index)
            else {
                return
            }
            parent.onOpen(parent.results[index])
        }

        func updateLayout(_ collectionView: NSCollectionView, width: CGFloat) {
            guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
            else {
                return
            }
            let columns = SearchResultGridProjection.columnCount(
                availableWidth: Double(width)
            )
            let spacing = layout.minimumInteritemSpacing * CGFloat(max(0, columns - 1))
            let inset = layout.sectionInset.left + layout.sectionInset.right
            let available = max(260, width - spacing - inset)
            layout.itemSize = NSSize(width: floor(available / CGFloat(columns)), height: 252)
        }

        func announceResultChange(on collectionView: NSCollectionView) {
            let count = parent.results.count
            guard count != lastAnnouncedCount else { return }
            let announcement = SearchResultGridProjection.accessibilityAnnouncement(
                previousCount: lastAnnouncedCount,
                currentCount: count,
                indexingBacklog: parent.indexingBacklog,
                hasNextPage: parent.hasNextPage
            )
            lastAnnouncedCount = count
            NSAccessibility.post(
                element: collectionView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }
}

@MainActor
private final class SearchResultNSCollectionView: NSCollectionView {
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class SearchResultCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SearchResultCollectionItem")

    private let preview = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let evidenceLabel = NSTextField(labelWithString: "")
    private let debugLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.cornerCurve = .continuous
        root.layer?.borderWidth = 0.5
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.07
        root.layer?.shadowRadius = 10
        root.layer?.shadowOffset = NSSize(width: 0, height: -2)

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 12
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        evidenceLabel.font = .systemFont(ofSize: 11)
        evidenceLabel.textColor = .secondaryLabelColor
        evidenceLabel.maximumNumberOfLines = 1
        evidenceLabel.lineBreakMode = .byTruncatingTail
        debugLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        debugLabel.textColor = .tertiaryLabelColor
        debugLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(
            views: [preview, titleLabel, metadataLabel, evidenceLabel, debugLabel]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 156),
        ])
        view = root
    }

    func configure(
        card: SearchResultCardProjection,
        image: NSImage?,
        selected: Bool,
        accessibilityIdentifier: String
    ) {
        preview.image = image ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        preview.contentTintColor = image == nil ? .tertiaryLabelColor : nil
        titleLabel.stringValue = card.title
        metadataLabel.stringValue = [card.timeText, card.applicationName, card.host]
            .compactMap { $0 }
            .joined(separator: " · ")
        let primaryEvidence = card.evidence[0]
        evidenceLabel.stringValue = primaryEvidence.displayText
        evidenceLabel.toolTip = "Source: \(primaryEvidence.sourceLabel)"
        debugLabel.stringValue = card.componentDebug?.displayText ?? ""
        debugLabel.isHidden = card.componentDebug == nil
        view.layer?.backgroundColor =
            (selected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16)
            : NSColor.controlBackgroundColor).cgColor
        view.layer?.borderColor =
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        view.layer?.borderWidth = selected ? 2 : 0.5
        view.layer?.shadowOpacity = selected ? 0.12 : 0.07
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityLabel(
            "\(card.accessibilityLabel), \(primaryEvidence.sourceLabel), "
                + primaryEvidence.displayText
        )
        view.setAccessibilityHelp("Press Return to open detail")
    }
}
