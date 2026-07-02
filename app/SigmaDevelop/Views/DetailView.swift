import SwiftUI
import UIKit

struct DetailView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.verticalSizeClass) private var vSizeClass
    let item: LibraryItem

    @State private var settings: DevelopSettings
    @State private var preview: UIImage?
    @State private var previewIsHDR = false
    @State private var autoExposureEV: Float?
    @State private var isExporting = false
    @State private var isRendering = false
    @State private var errorTitle = "Render Failed"
    @State private var errorText: String?
    @State private var shareItems: [URL] = []
    @State private var isSharing = false
    @State private var trayDetent: TrayDetent = .collapsed
    @State private var trayHeaderHeight: CGFloat = 53   // measured; pre-measure fallback

    init(item: LibraryItem) {
        self.item = item
        _settings = State(initialValue: item.settings)
    }

    /// immersive landscape
    private var isLandscape: Bool { vSizeClass == .compact }

    var body: some View {
        GeometryReader { proxy in
            // `proxy` itself respects the safe area, so this reads the true home-indicator inset
            let bottomInset = isLandscape ? 0 : proxy.safeAreaInsets.bottom
            let trayH = trayHeight(total: proxy.size.height, bottomInset: bottomInset)
            VStack(spacing: 0) {
                imageStage
                    // Pin the stage on changes
                    .frame(height: isLandscape ? nil : max(proxy.size.height + bottomInset - trayH, 0))

                if !isLandscape {
                    tray(bottomInset: bottomInset)
                        .frame(height: trayH, alignment: .top)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Portrait runs the tray through the bottom safe area so its ScrollView reaches the
            // physical edge & content flows to the bottom exactly like the global develop sheet
            .ignoresSafeArea(.container, edges: isLandscape ? .all : .bottom)
        }
            .background(SigmaTheme.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
            .toolbarBackground(SigmaTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .statusBarHidden(isLandscape)
            .persistentSystemOverlays(isLandscape ? .hidden : .automatic)
            .toolbar {
                ToolbarItem(placement: .principal) { SigmaWordmark(height: 15) }
                ToolbarItem(placement: .topBarTrailing) { exportMenu }
            }
            .sheet(isPresented: $isSharing) { ShareSheet(items: shareItems) }
            .alert(errorTitle, isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .task(id: settings.renderKey) { await renderPreview() }
            .onChange(of: settings) { _, _ in store.updateSettings(settings, for: item) }
            .onAppear { OrientationLock.allowsRotation = true }
            .onDisappear {
                OrientationLock.allowsRotation = false
                if settings != item.settings {
                    if let preview {
                        store.adoptThumbnail(from: preview, for: item.id)
                    } else {
                        store.refreshThumbnail(item.id)
                    }
                }
                store.engine.releaseCache()
            }
    }

    // MARK: - Image

    private var imageStage: some View {
        ZStack {
            if let preview {
                ZoomableImage(image: preview, isHDR: previewIsHDR,
                              insetH: SigmaTheme.stageInsetH, insetV: SigmaTheme.stageInsetV)
            } else if let thumb = store.thumbnails[item.id] {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, SigmaTheme.stageInsetH)
                    .padding(.vertical, SigmaTheme.stageInsetV)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 8)
                    .opacity(0.5)
            } else {
                ProgressView().controlSize(.large)
            }

            if isBusy {
                ProgressView()
                    .padding(11)
                    .glassEffect(in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SigmaTheme.surface)
        .clipped()
        .padding(.top, isLandscape ? 0 : SigmaTheme.contentTopInset)
        .contextMenu { exportActions }
    }

    // MARK: - Tray

    private enum TrayDetent: Int, CaseIterable {
        case hidden, collapsed, expanded
    }

    private var trayHeader: some View {
        VStack(spacing: 6) {
            grabHandle
            HStack(spacing: 0) {
                Text("Develop")
                    .font(.headline)
                    .foregroundStyle(SigmaTheme.ink)
                Spacer(minLength: 0)
                Button { settings = .init() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                }
                .tint(SigmaTheme.ink)
            }
        }
        .contentShape(Rectangle())
        .gesture(trayDrag)
    }

    private var grabHandle: some View {
        Capsule()
            .fill(SigmaTheme.ink.opacity(0.85))
            .frame(width: 38, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleTray)
            .accessibilityLabel(trayDetent == .expanded ? "Collapse controls" : "Expand controls")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggleTray)
    }

    private func toggleTray() {
        let next: TrayDetent = switch trayDetent {
        case .hidden: .collapsed
        case .collapsed: .expanded
        case .expanded: .collapsed
        }
        setTrayDetent(next)
    }

    private var trayDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let projected = value.predictedEndTranslation.height
                guard abs(projected) > 40 else { return }
                let step = projected < 0 ? 1 : -1
                let next = TrayDetent(rawValue: trayDetent.rawValue + step) ?? trayDetent
                setTrayDetent(next)
            }
    }

    private func setTrayDetent(_ detent: TrayDetent) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            trayDetent = detent
        }
    }

    private func tray(bottomInset: CGFloat) -> some View {
        VStack(spacing: 12) {
            trayHeader
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trayHeaderHeight = $0 }
                // Hidden shows exactly the header
                .padding(.bottom, trayDetent == .hidden ? bottomInset : 0)
            ScrollView {
                DevelopControls(settings: $settings, isX3F: item.isX3F,
                                autoExposureEV: autoExposureEV)
                    .padding(.horizontal, 4)
            }
            .scrollIndicators(.never)
            // Disable liquid glass effect as we have nothing there at the bottom
            .scrollEdgeEffectHidden(true, for: .all)
            // The scroll region runs to the physical bottom; re-inset the content above the home bar
            .contentMargins(.bottom, bottomInset + 8, for: .scrollContent)
            // off-screen when hidden, but keep VoiceOver from wandering below the fold
            .accessibilityHidden(trayDetent == .hidden)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        // Fill the height the outer `.frame(height:)` hands down so the ScrollView owns the
        // whole panel instead of shrinking to its content and stranding rows above dead paper.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(SigmaTheme.ink)
        .tint(SigmaTheme.ink)
        // Paper fills the panel down to the physical edge; the safe-area content inset keeps the
        // controls clear of the home indicator while the surface reads continuous to the bottom.
        .background(SigmaTheme.paper)
        .overlay(alignment: .top) {
            Divider()
                .overlay(SigmaTheme.hairline)
        }
    }

    private var exportMenu: some View {
        Menu {
            exportActions
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(isExporting)
        .tint(SigmaTheme.ink)
    }

    @ViewBuilder private var exportActions: some View {
        ForEach(item.availableFormats) { format in
            Button { Task { await exportAndShare(format) } } label: {
                Label("Export \(format.label)", systemImage: "square.and.arrow.up")
            }
            .disabled(isExporting)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private var isBusy: Bool { isRendering || isExporting }

    private func trayHeight(total: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let collapsed = min(max(total * 0.55, 340), 560)
        let visible: CGFloat = switch trayDetent {
        case .hidden: trayHeaderHeight + 8   // tray top padding + the measured header
        case .collapsed: collapsed
        case .expanded: max(collapsed, total * 0.9)
        }
        // Extend the panel through the bottom safe area so it reaches the physical edge; the
        // portion visible above the home indicator is unchanged from the detent height.
        return visible + bottomInset
    }

    // MARK: - Rendering

    private func renderPreview() async {
        if !settings.hdr { previewIsHDR = false }

        // Debounce rapid slider drags, but paint the first preview immediately.
        if preview != nil {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
        }

        let renderKey = settings.renderKey
        isRendering = true
        defer {
            if settings.renderKey == renderKey { isRendering = false }
        }
        do {
            let rendered = try await store.engine.preview(url: item.url, settings: settings, maxDimension: 2560)
            guard !Task.isCancelled else { return }
            preview = UIImage(cgImage: rendered.cgImage)
            previewIsHDR = rendered.isHDR
            autoExposureEV = rendered.autoExposureEV
            errorText = nil
        } catch {
            if !Task.isCancelled {
                errorTitle = "Render Failed"
                errorText = error.localizedDescription
            }
        }
    }

    private func exportAndShare(_ format: ExportFormat) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await store.export(item, settings: settings, as: format)
            shareItems = [url]
            isSharing = true
        } catch {
            errorTitle = "Export Failed"
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Zoomable image

/// Native pinch-, pan-, and double-tap-zoomable image clipped to its containing box.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// Only opt into the display's extended range when the render is actually an
    /// HDR/EDR image — otherwise an ordinary SDR preview would be shown boosted.
    var isHDR: Bool = false
    var insetH: CGFloat = 0
    var insetV: CGFloat = 0

    private let maxScale: CGFloat = 6
    private let doubleTapScale: CGFloat = 2.5

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.delegate = context.coordinator
        // Photos-style feel: crisp stops when panning a zoomed image.
        scrollView.decelerationRate = .fast
        scrollView.maximumZoomScale = maxScale
        scrollView.minimumZoomScale = 1
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.addSubview(context.coordinator.imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView

        // SwiftUI doesn't re-invoke `updateUIView` for a pure bounds change, so the
        // first non-zero layout (the scroll view starts at .zero) is reported here —
        // without this the image stays unsized until some state forces an update.
        let coordinator = context.coordinator
        scrollView.onLayout = { [weak scrollView] size in
            guard let scrollView, size.width > 0, size.height > 0,
                  coordinator.boundsSize != size else { return }
            coordinator.boundsSize = size
            coordinator.layoutContent(in: scrollView, resetZoom: false)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        let imageSizeChanged = coordinator.imageSize != image.size
        let boundsChanged = coordinator.boundsSize != scrollView.bounds.size
        let insetChanged = coordinator.insetH != insetH || coordinator.insetV != insetV

        coordinator.insetH = insetH
        coordinator.insetV = insetV
        coordinator.maxScale = maxScale
        coordinator.doubleTapScale = doubleTapScale
        coordinator.imageView.preferredImageDynamicRange = isHDR ? .high : .standard

        if coordinator.imageView.image !== image {
            coordinator.imageView.image = image
        }

        guard imageSizeChanged || boundsChanged || insetChanged else {
            coordinator.centerContent(in: scrollView)
            return
        }

        coordinator.imageSize = image.size
        coordinator.boundsSize = scrollView.bounds.size
        coordinator.layoutContent(in: scrollView, resetZoom: imageSizeChanged)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        var boundsSize: CGSize = .zero
        var doubleTapScale: CGFloat = 2.5
        var imageSize: CGSize = .zero
        var maxScale: CGFloat = 4
        var insetH: CGFloat = 0
        var insetV: CGFloat = 0

        override init() {
            super.init()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = true
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
        }

        func layoutContent(in scrollView: UIScrollView, resetZoom: Bool) {
            guard let image = imageView.image, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else {
                return
            }

            let zoomScale = scrollView.zoomScale
            let fittedSize = fittedSize(for: image.size, in: scrollView.bounds.size)
            // `frame` is the post-zoom-transform box: assigning it while zoomed
            // silently shrinks the base geometry (zoomScale stays high while the
            // image reads as fitted, so the next double-tap "toggles" outward).
            // Neutralise the zoom, re-base the geometry, then restore.
            scrollView.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = maxScale
            scrollView.zoomScale = resetZoom ? 1 : min(max(zoomScale, 1), maxScale)

            centerContent(in: scrollView)
        }

        func centerContent(in scrollView: UIScrollView) {
            let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: verticalInset,
                                                  left: horizontalInset,
                                                  bottom: verticalInset,
                                                  right: horizontalInset)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let targetScale = min(doubleTapScale, scrollView.maximumZoomScale)

            // Treat a near-fitted layout as not zoomed. Tray resizes can leave UIKit at a
            // small fractional scale above minimum; double-tap should still zoom in there.
            if scrollView.zoomScale >= targetScale * 0.85 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let location = recognizer.location(in: imageView)
            let clampedLocation = CGPoint(x: min(max(location.x, imageView.bounds.minX), imageView.bounds.maxX),
                                          y: min(max(location.y, imageView.bounds.minY), imageView.bounds.maxY))
            let zoomSize = CGSize(width: scrollView.bounds.width / targetScale,
                                  height: scrollView.bounds.height / targetScale)
            let zoomOrigin = CGPoint(x: clampedLocation.x - zoomSize.width / 2,
                                     y: clampedLocation.y - zoomSize.height / 2)
            scrollView.zoom(to: CGRect(origin: zoomOrigin, size: zoomSize), animated: true)
        }

        private func fittedSize(for imageSize: CGSize, in bounds: CGSize) -> CGSize {
            guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
                return bounds
            }
            let insetX = min(insetH, bounds.width / 2)
            let insetY = min(insetV, bounds.height / 2)
            let available = CGSize(width: max(1, bounds.width - insetX * 2),
                                   height: max(1, bounds.height - insetY * 2))
            let imageAspect = imageSize.width / imageSize.height
            let availableAspect = available.width / available.height
            if imageAspect > availableAspect {
                return CGSize(width: available.width, height: available.width / imageAspect)
            } else {
                return CGSize(width: available.height * imageAspect, height: available.height)
            }
        }
    }
}

/// Scroll view that surfaces geometry changes UIKit performs outside of SwiftUI's
/// `updateUIView` cycle, so the image can lay out the first time it gets a real size.
private final class ZoomScrollView: UIScrollView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}
