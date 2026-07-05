import SwiftUI
import UIKit

struct DetailView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.verticalSizeClass) private var vSizeClass
    @Environment(\.scenePhase) private var scenePhase
    let item: LibraryItem

    @State private var settings: DevelopSettings
    @State private var preview: UIImage?
    @State private var previewIsHDR = false
    @State private var autoExposureEV: Float?
    @State private var lensProfileAvailable = true
    /// Until a render says otherwise, assume native res — never tile blindly.
    @State private var previewIsNativeRes = true
    @State private var isExporting = false
    @State private var isRendering = false
    @State private var isTileRendering = false
    @State private var zoomTile: ZoomTile?
    @State private var tileTask: Task<Void, Never>?
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
            // Renders that raced backgrounding come back black (no GPU off
            // foreground); repaint — tiles re-request off the fresh image.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await renderPreview() } }
            }
            .onAppear { OrientationLock.allowsRotation = true }
            .onDisappear {
                OrientationLock.allowsRotation = false
                tileTask?.cancel()
                if settings != item.settings {
                    if let preview {
                        store.adoptThumbnail(from: preview, for: item.id)
                    } else {
                        store.refreshThumbnail(item.id)
                    }
                }
                store.engine.releaseTransient()
            }
    }

    // MARK: - Image

    private var imageStage: some View {
        ZStack {
            if let preview {
                // Tiles engage only when the base preview undersells the file's
                // native grid — resolution-driven, so it holds for RAW and X3F
                // alike (an X3F at the native 2640 grid never tiles; anything
                // rendered under the cap does). Film sim is excluded because
                // grain reseeds per render and would seam against the base.
                ZoomableImage(image: preview, isHDR: previewIsHDR, tile: zoomTile,
                              insetH: SigmaTheme.stageInsetH, insetV: SigmaTheme.stageInsetV,
                              onTileNeeded: settings.filmEnabled || previewIsNativeRes ? nil : handleTileRequest)
            } else if let thumb = store.thumbnails[item.id] {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, SigmaTheme.stageInsetH)
                    .padding(.vertical, SigmaTheme.stageInsetV)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 8)
                    .opacity(0.5)
            }

            // classic springboard spinner :D
            ActivitySpinner(animating: isBusy)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SigmaTheme.surface)
        .clipped()
        .padding(.top, isLandscape ? 0 : SigmaTheme.contentTopInset)
        .contextMenu {
            rotateActions
            Divider()
            exportActions
        } preview: {
            liftPreview
        }
    }

    /// The lift platter hugs the photo — no mat, no letterboxing; landscape
    /// bars only ever come from the stage itself when the device is rotated.
    @ViewBuilder private var liftPreview: some View {
        if let image = preview ?? store.thumbnails[item.id] {
            let h = (320 * image.size.height / max(image.size.width, 1)).rounded()
            Image(uiImage: image)
                .resizable()
                .frame(width: 320, height: h)
        }
    }

    @ViewBuilder private var rotateActions: some View {
        Button { rotate(by: 1) } label: { Label("Rotate Right", systemImage: "rotate.right") }
        Button { rotate(by: -1) } label: { Label("Rotate Left", systemImage: "rotate.left") }
    }

    private func rotate(by turns: Int) {
        settings.rotation = (((settings.rotation + turns) % 4) + 4) % 4
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
    }

    // Detents switch on release: live tracking would resize the stage per frame
    // (fighting the zoom re-base) and move the header under the finger,
    // oscillating the gesture's own translation.
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
                // No containerRelativeFrame here: it resolves against the
                // screen, not this padded scroll view, and pushes the panel's
                // right edge off screen. The scroll view already proposes its
                // own width; every row compresses (stock menus truncate).
                DevelopControls(settings: $settings, isX3F: item.isX3F,
                                autoExposureEV: autoExposureEV,
                                lensCorrectionAvailable: lensProfileAvailable)
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

    private var isBusy: Bool { isRendering || isExporting || isTileRendering }

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
        let renderKey = settings.renderKey
        isRendering = true
        // in-flight tile was rendered for the previous settings.
        cancelTileTask()
        defer {
            if settings.renderKey == renderKey { isRendering = false }
        }
        do {
            // X3F first paint comes from the cached proxy decode
            for try await rendered in store.engine.previewUpdates(url: item.url, settings: settings, maxDimension: 2560) {
                guard !Task.isCancelled else { return }
                preview = UIImage(cgImage: rendered.cgImage)
                previewIsHDR = rendered.isHDR
                previewIsNativeRes = rendered.isAtNativeSize
                autoExposureEV = rendered.autoExposureEV
                if item.isX3F { lensProfileAvailable = rendered.lensProfileAvailable }
                // Stale for the new pixels; the zoom view re-requests as needed
                if zoomTile != nil { zoomTile = nil }
                errorText = nil
            }
        } catch {
            if !Task.isCancelled {
                errorTitle = "Render Failed"
                errorText = error.localizedDescription
            }
        }
    }

    /// deep zoom tile flow
    private func handleTileRequest(_ request: ZoomTileRequest?) {
        guard let request else {
            cancelTileTask()
            if zoomTile != nil { zoomTile = nil }
            return
        }
        // A capped tile re-emits its own request on settle; it's already applied.
        guard zoomTile?.request != request else { return }
        // Never race an in-flight preview render (it may still be swapping a
        // progressive proxy for the full develop); the fresh image re-emits
        // the request from `updateUIView` once it lands.
        guard !isRendering else { return }
        tileTask?.cancel()
        tileTask = Task {
            isTileRendering = true
            // A superseding task owns the flag from the moment it cancels this
            // one; only a task that ran to completion may clear it.
            defer { if !Task.isCancelled { isTileRendering = false } }
            guard let (rendered, actual) = try? await store.engine.regionPreview(
                    url: item.url, settings: settings,
                    region: request.region, maxDimension: request.longEdge),
                  !Task.isCancelled else { return }
            zoomTile = ZoomTile(image: UIImage(cgImage: rendered.cgImage),
                                region: actual, isHDR: rendered.isHDR, request: request)
        }
    }

    private func cancelTileTask() {
        tileTask?.cancel()
        tileTask = nil
        isTileRendering = false
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

/// Render the visible region sharp on tile zoom
struct ZoomTile {
    let id = UUID()
    let image: UIImage
    /// Unit rect the engine actually rendered (top-left origin) — the overlay
    /// is placed here, exactly on the pixel grid the tile was cut from.
    let region: CGRect
    let isHDR: Bool
    let request: ZoomTileRequest
}

/// Visible region and target pixel long edge for a sharpening tile.
struct ZoomTileRequest: Equatable {
    let region: CGRect
    let longEdge: Int
}

/// Cspinner :D
private struct ActivitySpinner: UIViewRepresentable {
    var animating: Bool

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.hidesWhenStopped = true
        spinner.color = .white
        spinner.layer.shadowColor = UIColor.black.cgColor
        spinner.layer.shadowOpacity = 0.4
        spinner.layer.shadowRadius = 2
        spinner.layer.shadowOffset = .zero
        return spinner
    }

    func updateUIView(_ spinner: UIActivityIndicatorView, context: Context) {
        if animating, !spinner.isAnimating {
            spinner.startAnimating()
        } else if !animating, spinner.isAnimating {
            spinner.stopAnimating()
        }
    }
}

/// Native pinch-, pan-, and double-tap-zoomable image clipped to its containing box.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// Only opt into the display's extended range when the render is actually an
    /// HDR/EDR image — otherwise an ordinary SDR preview would be shown boosted.
    var isHDR: Bool = false
    var tile: ZoomTile? = nil
    var insetH: CGFloat = 0
    var insetV: CGFloat = 0
    var onTileNeeded: ((ZoomTileRequest?) -> Void)? = nil

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
        let imageChanged = coordinator.imageView.image !== image
        let imageSizeChanged = coordinator.imageSize != image.size
        let boundsChanged = coordinator.boundsSize != scrollView.bounds.size
        let insetChanged = coordinator.insetH != insetH || coordinator.insetV != insetV

        coordinator.insetH = insetH
        coordinator.insetV = insetV
        coordinator.maxScale = maxScale
        coordinator.doubleTapScale = doubleTapScale
        coordinator.onTileNeeded = onTileNeeded
        coordinator.imageView.preferredImageDynamicRange = isHDR ? .high : .standard

        if imageChanged {
            coordinator.imageView.image = image
        }
        let resolvedTile = imageChanged ? nil : tile
        if coordinator.appliedTile?.id != resolvedTile?.id {
            coordinator.setTile(resolvedTile)
        }
        if imageChanged {
            DispatchQueue.main.async { [weak coordinator] in coordinator?.maybeRequestTile() }
        }

        guard imageSizeChanged || boundsChanged || insetChanged else {
            coordinator.centerContent(in: scrollView)
            return
        }

        // A sharper render of the same photo
        let oldSize = coordinator.imageSize
        let aspectChanged = oldSize.height <= 0 || image.size.height <= 0
            || abs(oldSize.width / oldSize.height - image.size.width / image.size.height) > 0.001

        coordinator.imageSize = image.size
        coordinator.boundsSize = scrollView.bounds.size
        coordinator.layoutContent(in: scrollView, resetZoom: imageSizeChanged && aspectChanged)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        private let tileView = UIImageView()
        weak var scrollView: UIScrollView?

        var boundsSize: CGSize = .zero
        var doubleTapScale: CGFloat = 2.5
        var imageSize: CGSize = .zero
        var maxScale: CGFloat = 4
        var insetH: CGFloat = 0
        var insetV: CGFloat = 0
        var onTileNeeded: ((ZoomTileRequest?) -> Void)?
        private(set) var appliedTile: ZoomTile?

        /// zoom in overshoot corners
        private static let zoomedCornerFraction: CGFloat = 0.22
        /// Ask for a sharper tile
        private static let tileTriggerDensity: CGFloat = 1.2
        /// Extra half-viewport rendered on edge
        private static let tilePadFraction: CGFloat = 0.5
        private static let tileMaxLongEdge: CGFloat = 2560

        override init() {
            super.init()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = true
            // The tile's frame is fill region
            tileView.contentMode = .scaleToFill
            tileView.isHidden = true
            imageView.addSubview(tileView)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            maybeRequestTile()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { maybeRequestTile() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            maybeRequestTile()
        }

        func layoutContent(in scrollView: UIScrollView, resetZoom: Bool) {
            guard let image = imageView.image, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else {
                return
            }

            let fittedSize = fittedSize(for: image.size, in: scrollView.bounds.size)
            // Same base geometry (a sharper render of the same layout): skip the
            // re-base entirely so swapping pixels never touches scroll state.
            if !resetZoom,
               abs(imageView.bounds.width - fittedSize.width) < 0.5,
               abs(imageView.bounds.height - fittedSize.height) < 0.5 {
                scrollView.maximumZoomScale = maxScale
                centerContent(in: scrollView)
                return
            }

            // `frame` is the post-zoom-transform box: assigning it while zoomed
            // silently shrinks the base geometry (zoomScale stays high while the
            // image reads as fitted, so the next double-tap "toggles" outward).
            // Neutralise the zoom, re-base the geometry, then restore
            UIView.performWithoutAnimation {
                let zoomScale = scrollView.zoomScale
                scrollView.zoomScale = 1
                imageView.frame = CGRect(origin: .zero, size: fittedSize)
                scrollView.contentSize = fittedSize
                scrollView.minimumZoomScale = 1
                scrollView.maximumZoomScale = maxScale
                scrollView.zoomScale = resetZoom ? 1 : min(max(zoomScale, 1), maxScale)
                layoutTile()
                centerContent(in: scrollView)
            }
        }

        func centerContent(in scrollView: UIScrollView) {
            // Breathing room grows with zoom (fully by 1.5×) so a corner can be
            // pulled well clear of the stage edge.
            let t = min(max((scrollView.zoomScale - 1) / 0.5, 0), 1)
            let padH = insetH + (max(scrollView.bounds.width * Self.zoomedCornerFraction, insetH) - insetH) * t
            let padV = insetV + (max(scrollView.bounds.height * Self.zoomedCornerFraction, insetV) - insetV) * t
            // Floor the centring insets at the stage insets for zoom
            let floorH = min(padH, scrollView.bounds.width / 2)
            let floorV = min(padV, scrollView.bounds.height / 2)
            let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, floorH)
            let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, floorV)
            scrollView.contentInset = UIEdgeInsets(top: verticalInset,
                                                  left: horizontalInset,
                                                  bottom: verticalInset,
                                                  right: horizontalInset)
        }

        // MARK: Deep-zoom tiles

        func setTile(_ tile: ZoomTile?) {
            appliedTile = tile
            tileView.image = tile?.image
            tileView.preferredImageDynamicRange = (tile?.isHDR ?? false) ? .high : .standard
            tileView.isHidden = tile == nil
            layoutTile()
        }

        private func layoutTile() {
            guard let region = appliedTile?.region else { return }
            let base = imageView.bounds.size
            tileView.frame = CGRect(x: region.minX * base.width,
                                    y: region.minY * base.height,
                                    width: region.width * base.width,
                                    height: region.height * base.height)
        }

        /// Report a padded region whenever the displayed size outruns the base
        /// preview's pixels — and rescind (nil) when it no longer does. While the
        /// viewport stays inside the applied tile at full density, nothing is
        /// emitted, so panning never swaps or drops a tile that still covers.
        func maybeRequestTile() {
            guard let scrollView, let onTileNeeded else { return }
            guard !scrollView.isZooming, !scrollView.isDragging, !scrollView.isDecelerating else { return }
            let fitted = imageView.bounds.size
            let zoom = scrollView.zoomScale
            guard zoom > 1.02, fitted.width > 0, fitted.height > 0,
                  imageSize.width > 0, imageSize.height > 0 else {
                return onTileNeeded(nil)
            }
            let visible = scrollView.convert(scrollView.bounds, to: imageView)
                .intersection(CGRect(origin: .zero, size: fitted))
            guard !visible.isEmpty else { return onTileNeeded(nil) }

            let displayScale = max(scrollView.traitCollection.displayScale, 1)
            // Screen pixels the region paints vs base-preview pixels backing it.
            let displayedPx = max(visible.width, visible.height) * zoom * displayScale
            let sourcePx = max(visible.width / fitted.width * imageSize.width,
                               visible.height / fitted.height * imageSize.height)
            guard displayedPx > sourcePx * Self.tileTriggerDensity else { return onTileNeeded(nil) }

            let visibleUnit = CGRect(x: visible.minX / fitted.width,
                                     y: visible.minY / fitted.height,
                                     width: visible.width / fitted.width,
                                     height: visible.height / fitted.height)
            if let tile = appliedTile,
               tile.region.insetBy(dx: -0.001, dy: -0.001).contains(visibleUnit) {
                let tilePx = max(tile.image.size.width, tile.image.size.height) * tile.image.scale
                let tileScreenPx = max(tile.region.width * fitted.width,
                                       tile.region.height * fitted.height) * zoom * displayScale
                if tilePx >= tileScreenPx * 0.95 { return }
            }

            let padded = visible.insetBy(dx: -visible.width * Self.tilePadFraction,
                                         dy: -visible.height * Self.tilePadFraction)
                .intersection(CGRect(origin: .zero, size: fitted))
            let paddedPx = max(padded.width, padded.height) * zoom * displayScale
            let region = CGRect(x: padded.minX / fitted.width,
                                y: padded.minY / fitted.height,
                                width: padded.width / fitted.width,
                                height: padded.height / fitted.height)
            onTileNeeded(ZoomTileRequest(region: region,
                                         longEdge: Int(min(paddedPx.rounded(.up), Self.tileMaxLongEdge))))
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
