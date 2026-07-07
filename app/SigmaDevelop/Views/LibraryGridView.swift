import SwiftUI

struct LibraryGridView: View {
    @Environment(LibraryStore.self) private var store

    @State private var isImporting = false
    @State private var showOptions = false
    @State private var shareItems: [URL] = []
    @State private var isSharing = false
    @State private var isExportingAll = false
    @State private var exportingItemID: UUID?
    @State private var errorText: String?
    @State private var page: Page? = .gallery

    private enum Page: Hashable { case gallery, cover }

    private let columnCount = 2
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 0),
        GridItem(.flexible(minimum: 0), spacing: 0),
    ]

    var body: some View {
        content
            .sigmaBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(SigmaTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { SigmaWordmark() }
                if !store.items.isEmpty, page == .gallery {
                    ToolbarItem(placement: .topBarLeading) { pageToggle }
                    ToolbarItem(placement: .topBarTrailing) { menu }
                }
            }
            .navigationDestination(for: LibraryItem.self) { DetailView(item: $0) }
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: ImportTypes.content,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task {
                        await store.importPicked(urls)
                        withAnimation { page = .gallery }
                    }
                }
            }
            .sheet(isPresented: $showOptions) { DevelopOptionsSheet().environment(store) }
            .sheet(isPresented: $isSharing) { ShareSheet(items: shareItems) }
            .alert("Export Failed", isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .overlay(alignment: .bottom) {
                if !store.items.isEmpty {
                    importButton
                        .opacity(page == .cover ? 0 : 1)
                        .allowsHitTesting(page != .cover)
                        .animation(.easeInOut(duration: 0.2), value: page)
                }
            }
            .overlay { if isExporting || store.isImporting { progressOverlay } }
    }

    // MARK: - Pages

    @ViewBuilder private var content: some View {
        if store.items.isEmpty {
            LandingView(hasItems: false) { isImporting = true }
        } else {
            pager
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                LandingView(hasItems: true) { isImporting = true }
                    .containerRelativeFrame(.horizontal)
                    .id(Page.cover)
                gallery
                    .containerRelativeFrame(.horizontal)
                    .id(Page.gallery)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .defaultScrollAnchor(.trailing)
        .scrollIndicators(.hidden)
    }

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    GalleryCell(item: item, index: index, columnCount: columnCount,
                                isExporting: isExporting) { item, format in
                        Task { await export(item, as: format) }
                    }
                }
            }
        }
        .background(SigmaTheme.paper)
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.top, SigmaTheme.contentTopInset, for: .scrollContent)
    }

    // MARK: - Chrome

    /// Jumps to the other page in one tap — a deterministic counterpart to the swipe,
    /// so the cover is reachable (and escapable) without relying on the gesture.
    private var pageToggle: some View {
        Button {
            withAnimation { page = (page == .cover) ? .gallery : .cover }
        } label: {
            Text("\(store.items.count)")
                .sigmaLabel(size: 11, color: SigmaTheme.ink, tracking: 1.1)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page == .cover ? "Show library" : "Show cover")
    }

    private var menu: some View {
        Menu {
            Button { showOptions = true } label: {
                Label("Develop Options", systemImage: "slider.horizontal.3")
            }
            Button { Task { await runExportAll() } } label: {
                Label("Export All", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(store.items.isEmpty || isExporting)
        } label: {
            Image(systemName: "ellipsis")
        }
        .tint(SigmaTheme.ink)
    }

    private var importButton: some View {
        Button { isImporting = true } label: {
            Label("Import", systemImage: "plus")
                .font(.body.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(SigmaTheme.ink)
        .padding(.bottom, 12)
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            ProgressCard(verb: isExporting ? "Developing" : "Importing")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private var isExporting: Bool { isExportingAll || exportingItemID != nil }

    // MARK: - Export all

    private func runExportAll() async {
        guard !isExporting else { return }
        isExportingAll = true
        defer { isExportingAll = false }
        do {
            shareItems = try await store.exportAll()
            isSharing = !shareItems.isEmpty
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func export(_ item: LibraryItem, as format: ExportFormat) async {
        guard !isExporting else { return }
        exportingItemID = item.id
        defer { exportingItemID = nil }
        do {
            shareItems = [try await store.export(item, settings: item.settings, as: format)]
            isSharing = true
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Progress card

/// Read per-file progress counts in their own body,each tick re-evaluates alone
private struct ProgressCard: View {
    @Environment(LibraryStore.self) private var store
    let verb: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .sigmaText(.subheadline)
                .foregroundStyle(SigmaTheme.ink)
                .monospacedDigit()
        }
        .padding(28)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var title: String {
        guard let progress = store.exportProgress ?? store.importProgress else { return verb }
        return "\(verb) \(progress.done) of \(progress.total)"
    }
}

// MARK: - Gallery cell

/// One grid cell. Reading `store.thumbnails` here — instead of up in
/// `LibraryGridView.body` — scopes the redraw that each async thumbnail triggers to
/// the handful of *visible* cells, rather than re-evaluating the whole screen (the
/// toolbar, overlays and the full item `ForEach`) every time one more thumbnail
/// finishes decoding.
private struct GalleryCell: View {
    @Environment(LibraryStore.self) private var store
    let item: LibraryItem
    let index: Int
    let columnCount: Int
    let isExporting: Bool
    let onExport: (LibraryItem, ExportFormat) -> Void

    var body: some View {
        NavigationLink(value: item) {
            LibraryCard(item: item, thumbnail: store.thumbnails[item.id])
        }
        .buttonStyle(.plain)
        // Keyed on presence so an LRU-evicted thumbnail is re-requested when it
        // goes nil while the cell is on screen, not only on first appearance.
        .task(id: store.thumbnails[item.id] == nil) { store.ensureThumbnail(item) }
        // Hairline separators drawn per cell (top edge below the first row, leading
        // edge right of the first column) — no grid-sized background layer that could
        // seam or flicker while scrolling.
        .overlay(alignment: .top) {
            if index >= columnCount {
                Rectangle().fill(SigmaTheme.hairline).frame(height: 1)
            }
        }
        .overlay(alignment: .leading) {
            if index % columnCount != 0 {
                Rectangle().fill(SigmaTheme.hairline).frame(width: 1)
            }
        }
        .contextMenu {
            Button { store.rotate(item, quarterTurns: 1) } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            Button { store.rotate(item, quarterTurns: -1) } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }

            Divider()

            ForEach(item.availableFormats) { format in
                Button { onExport(item, format) } label: {
                    Label("Export \(format.label)", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
            }

            Divider()

            Button(role: .destructive) { store.delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        } preview: {
            if let thumb = store.thumbnails[item.id] {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 320)
            }
        }
    }
}

// MARK: - Landing

private struct LandingView: View {
    var hasItems: Bool
    var onImport: () -> Void

    var body: some View {
        ZStack {
            SigmaTheme.paper.ignoresSafeArea()
            GeometryReader { proxy in
                VStack(spacing: 22) {
                    SigmaMark(size: 70)
                    VStack(spacing: 6) {
                        Text("Developer")
                            .sigmaText(.title, weight: .regular)
                            .foregroundStyle(SigmaTheme.ink)
                        Text("X3F / RAW")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SigmaTheme.secondary)
                    }
                    Button(action: onImport) {
                        SigmaActionLabel(hasItems ? "+ Import" : "Import")
                    }
                    .buttonStyle(.plain)
                }
                .padding(40)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct SigmaActionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .textCase(.uppercase)
            .foregroundStyle(SigmaTheme.ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 30)
            .background(SigmaTheme.surface)
            .overlay(Rectangle().stroke(SigmaTheme.ink, lineWidth: 0.8))
    }
}
