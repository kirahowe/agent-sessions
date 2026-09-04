import AppKit
import GhosttyTerminal
import SwiftUI

/// A single container for every active session's pane surfaces. Switching
/// the selected session only toggles visibility and focus; live views are
/// never reparented because that blanks their Metal surfaces. Workspace
/// closing is the deliberate exception: TerminalCenter removes and frees
/// each target surface while it is quiesced, and this host must not lazily
/// request a new one until the manager outcome resumes that session.
///
/// Split layout is applied by setting subview frames from the session's
/// `SessionPaneLayout` in the container's `layout()` pass — not with Auto
/// Layout constraints, and not with `NSSplitView`. Constraints would need a
/// full deactivate/reactivate cycle per divider-drag tick, and `NSSplitView`
/// would force reparenting the existing surface on first split; direct
/// frames give the same geometry with neither cost, and the pure
/// `paneFrames`/`dividers` math is unit-tested on the model.
///
/// Open review overlays (see `OverlayCenter`) are hosted in this same
/// container and shown the same way — by hiding their siblings rather than
/// by removing them. A review covers the session's entire pane area,
/// whatever the split layout: reviews are per session, not per pane.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var store: AppStore
    @ObservedObject var center: TerminalCenter
    @ObservedObject var overlays: OverlayCenter

    func makeNSView(context: Context) -> PaneHostContainerView {
        let containerView = PaneHostContainerView()
        containerView.onFocusPane = { [weak center] paneID in
            center?.focusPane(paneID)
        }
        return containerView
    }

    func updateNSView(_ containerView: PaneHostContainerView, context: Context) {
        // Every live overlay is mounted, not just the selected session's: a
        // review can be requested by a session that isn't on screen, and its
        // command process is spawned by libghostty only once the surface
        // exists, which requires the view to be in the hierarchy with a real
        // size. Mounting is not revealing: which subviews are visible is
        // decided below, so a hidden session's review runs behind the scenes.
        for overlayView in overlays.allViews {
            containerView.mountOverlay(overlayView)
        }

        guard let selectedID = store.selection else {
            containerView.presentNothing()
            return
        }

        // The selected session's own review owns its pane. Scoped to the
        // selection: another session's review must never take over work the
        // user is looking at — it stays mounted, hidden, and running, and
        // reselecting its session restores it exactly where it was.
        if let overlayView = overlays.view(forSession: selectedID) {
            containerView.present(overlay: overlayView)
            return
        }

        guard let row = store.sessions.first(where: { $0.id == selectedID }),
              !center.isSessionQuiesced(selectedID),
              center.ensureSession(
                  selectedID,
                  workingDirectory: store.workingDirectory(for: row),
                  restoredResume: row.resume
              ),
              let layout = center.layouts[selectedID]
        else {
            containerView.presentNothing()
            return
        }

        // Frames and dividers come out of the pure layout model in unit
        // space; the container scales them to its bounds in layout().
        let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let unitFrames = layout.tree.paneFrames(in: unitBounds)
        var paneItems: [PaneHostContainerView.PaneItem] = []
        for (paneID, unitFrame) in unitFrames {
            guard let paneView = center.view(forPane: paneID) else { continue }
            containerView.mount(paneView)
            paneItems.append(
                PaneHostContainerView.PaneItem(
                    paneID: paneID,
                    view: paneView,
                    unitFrame: unitFrame,
                    isFocused: paneID == layout.focusedPane
                )
            )
        }
        let dividerItems = layout.tree.dividers(in: unitBounds).map { divider in
            PaneHostContainerView.DividerItem(
                path: divider.path,
                axis: divider.axis,
                unitRegion: divider.region,
                ratio: divider.ratio,
                generation: layout.structureGeneration
            )
        }
        // Rebound each update so a drag always resizes the session the user
        // is looking at, never one selected earlier. The generation check
        // drops drag events captured against a tree a pane exit has since
        // reshaped: a collapsed node can leave the old path VALID but
        // addressing a different split (see SessionPaneLayout.structureGeneration),
        // and one runloop turn can pass before this view re-lays-out.
        containerView.onDividerDrag = { [weak center] path, ratio, generation in
            guard let center,
                  center.layouts[selectedID]?.structureGeneration == generation
            else { return }
            center.setRatio(in: selectedID, at: path, to: ratio)
        }
        center.showResumeHintIfNeeded(for: selectedID)
        containerView.present(panes: paneItems, dividers: dividerItems, context: selectedID)
    }
}

/// The AppKit half of the split-pane view layer: owns mounting, visibility,
/// frame layout, divider drags, click-to-focus, and the focus ring. All pane
/// surfaces remain direct children of this one view, mounted once and never
/// reparented.
///
/// Flipped (y-down) to match the layout model's geometry convention — see
/// PaneLayout.swift's header.
@MainActor
final class PaneHostContainerView: NSView {
    struct PaneItem {
        let paneID: UUID
        let view: NSView
        let unitFrame: CGRect
        let isFocused: Bool
    }

    struct DividerItem: Equatable {
        let path: [PaneBranch]
        let axis: SplitAxis
        let unitRegion: CGRect
        let ratio: Double
        /// The layout's `structureGeneration` when this divider was laid
        /// out. Drags report it so a resize captured against a tree that a
        /// pane exit has since reshaped can be dropped instead of resizing
        /// whatever split now happens to live at the same path.
        let generation: Int
    }

    private enum Presentation {
        case nothing
        case overlay(NSView)
        case panes
    }

    /// Fired with the pane the user clicked when it wasn't already focused.
    var onFocusPane: ((UUID) -> Void)?
    /// Fired continuously during a divider drag with the divider's path,
    /// the new ratio (the model clamps — this view only reports geometry),
    /// and the structure generation the divider was laid out against.
    var onDividerDrag: (([PaneBranch], Double, Int) -> Void)?

    private var presentation: Presentation = .nothing
    private var paneItems: [PaneItem] = []
    private var dividerItems: [DividerItem] = []
    private var dividerViews: [PaneDividerView] = []
    private var clickMonitor: Any?

    /// The mounted overlay surfaces (weak — OverlayCenter removes them from
    /// the hierarchy on dismissal and this must not keep them alive). Layout
    /// gives these full bounds even while hidden: a review runs, and its TUI
    /// draws, at real size in an unselected session, so reselecting restores
    /// it exactly where it was with no reflow. Hidden *pane* views keep
    /// their last frame instead — resizing a background session's shells on
    /// every window change would churn SIGWINCH through TUIs nobody can see.
    private let overlaySurfaces = NSHashTable<NSView>.weakObjects()

    /// Topmost chrome, present from init so every terminal mount can be
    /// positioned below it without ever re-adding (= reparenting) a live
    /// surface to fix z-order.
    private let focusRing = PaneFocusRingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRing.isHidden = true
        addSubview(focusRing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// y-down, matching the layout model — `.vertical` splits put `first`
    /// on top, and `FocusDirection.down` means larger y.
    override var isFlipped: Bool { true }

    /// Adds a surface view to the container, once. Repeat calls are no-ops:
    /// re-adding a live surface is exactly the reparenting that blanks it.
    /// Mounted views start hidden; presentation decides visibility.
    func mount(_ surfaceView: NSView) {
        guard surfaceView.superview !== self else { return }
        surfaceView.isHidden = true
        // Frames are assigned in layout(); autoresizing must not fight them.
        surfaceView.translatesAutoresizingMaskIntoConstraints = true
        surfaceView.autoresizingMask = []
        addSubview(surfaceView, positioned: .below, relativeTo: focusRing)
    }

    /// Mounts a review-overlay surface — see `overlaySurfaces` for how these
    /// are laid out differently from panes.
    func mountOverlay(_ surfaceView: NSView) {
        overlaySurfaces.add(surfaceView)
        mount(surfaceView)
        needsLayout = true
    }

    func presentNothing() {
        presentation = .nothing
        paneItems = []
        dividerItems = []
        setPresentationContext(nil)
        applyPresentation()
    }

    func present(overlay overlayView: NSView) {
        presentation = .overlay(overlayView)
        paneItems = []
        dividerItems = []
        setPresentationContext(nil)
        applyPresentation()
    }

    /// `context` is an opaque identity for WHOSE panes these are (the
    /// selected session). Presentation changes — a different session, an
    /// overlay, nothing — invalidate any in-flight divider drag: its
    /// latched item belongs to the previous presentation, and the
    /// generation alone can't tell two sessions apart (both counters can
    /// coincidentally hold the same value).
    func present(panes: [PaneItem], dividers: [DividerItem], context: String) {
        presentation = .panes
        paneItems = panes
        dividerItems = dividers
        setPresentationContext(context)
        applyPresentation()
    }

    private var presentationContext: String?

    private func setPresentationContext(_ context: String?) {
        guard presentationContext != context else { return }
        presentationContext = context
        activeDragItem = nil
    }

    private func applyPresentation() {
        let visibleSurfaces: Set<ObjectIdentifier>
        switch presentation {
        case .nothing:
            visibleSurfaces = []
        case .overlay(let overlayView):
            visibleSurfaces = [ObjectIdentifier(overlayView)]
        case .panes:
            visibleSurfaces = Set(paneItems.map { ObjectIdentifier($0.view) })
        }

        for subview in subviews {
            guard subview !== focusRing, !(subview is PaneDividerView) else { continue }
            subview.isHidden = !visibleSurfaces.contains(ObjectIdentifier(subview))
        }

        syncDividerPool()
        // Chrome must sit above every surface, and mounting keeps ordering
        // only relative to the ring — a pane mounted after a divider was
        // created would otherwise sit above that divider, swallowing part of
        // its visible line and its drag hit area. Re-adding moves a view to
        // the top; that reparenting is fatal for live Metal surfaces but
        // harmless for plain chrome views, so the chrome is what moves.
        for divider in dividerViews {
            addSubview(divider)
        }
        addSubview(focusRing)
        // The ring marks the focused pane only when there's a choice to
        // mark; a lone pane with a permanent ring would just be a border.
        focusRing.isHidden = !(presentationIsPanes && paneItems.count > 1)

        needsLayout = true
        focusCurrentSurface()
    }

    private var presentationIsPanes: Bool {
        if case .panes = presentation { return true }
        return false
    }

    /// Makes the presented surface (overlay, or the focused pane) first
    /// responder so keystrokes land where the user is looking. AppKit
    /// short-circuits when the view already is first responder, so calling
    /// this on every update is safe.
    private func focusCurrentSurface() {
        switch presentation {
        case .nothing:
            break
        case .overlay(let overlayView):
            window?.makeFirstResponder(overlayView)
        case .panes:
            guard let focused = paneItems.first(where: \.isFocused) else { break }
            window?.makeFirstResponder(focused.view)
        }
    }

    /// Grows/shrinks the divider pool to match `dividerItems` and hands each
    /// divider its drag geometry. Divider views are plain chrome — creating
    /// and removing them is cheap and reparents no surface.
    private func syncDividerPool() {
        while dividerViews.count < dividerItems.count {
            let divider = PaneDividerView()
            dividerViews.append(divider)
            addSubview(divider, positioned: .below, relativeTo: focusRing)
        }
        while dividerViews.count > dividerItems.count {
            dividerViews.removeLast().removeFromSuperview()
        }
        for (divider, item) in zip(dividerViews, dividerItems) {
            divider.isHidden = !presentationIsPanes
            divider.axis = item.axis
            divider.onDrag = { [weak self] pointInContainer, phase in
                self?.handleDividerDrag(item: item, point: pointInContainer, phase: phase)
            }
        }
    }

    /// The DividerItem captured at mouse-down, held for the whole drag.
    /// Every resize tick re-lays-out this view and rebinds the pooled
    /// divider's closure to a fresh item — which is fine while the tree's
    /// structure is unchanged, but a pane exiting mid-drag collapses a node
    /// and can leave the SAME path addressing a DIFFERENT split. Adopting
    /// the refreshed item then would carry the new generation and sail past
    /// the staleness guard, resizing a split the user never grabbed. The
    /// mouse-down item's generation goes stale instead, and the guard drops
    /// the rest of the drag.
    private var activeDragItem: DividerItem?

    private func handleDividerDrag(
        item: DividerItem, point: NSPoint, phase: PaneDividerView.DragPhase
    ) {
        switch phase {
        case .began:
            activeDragItem = item
        case .moved:
            break
        case .ended:
            activeDragItem = nil
            return
        }
        // No fallback to the rebound `item`: a .moved with no latch means
        // the drag began under a presentation that has since changed, and
        // resizing whatever now sits under the mouse would act on a split
        // the user never grabbed.
        guard let dragged = activeDragItem else { return }
        let scaled = scaledRect(dragged.unitRegion)
        let ratio: Double
        switch dragged.axis {
        case .horizontal:
            guard scaled.width > 0 else { return }
            ratio = Double((point.x - scaled.minX) / scaled.width)
        case .vertical:
            guard scaled.height > 0 else { return }
            ratio = Double((point.y - scaled.minY) / scaled.height)
        }
        onDividerDrag?(dragged.path, ratio, dragged.generation)
    }

    // MARK: - Layout

    /// Total grabbable thickness of a divider; the visible line inside it is
    /// hairline. Centered on the pane boundary, so it overlaps ~3.5pt of
    /// each neighbor's edge — clicks there hit the divider, which is the
    /// point of a hit area.
    private static let dividerThickness: CGFloat = 7

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Every overlay surface — visible or not — fills the container, so a
        // hidden review keeps running at real size (and so a freshly mounted
        // one has the real size libghostty needs before it builds the
        // surface and spawns the review).
        for overlaySurface in overlaySurfaces.allObjects where overlaySurface.superview === self {
            setSurfaceFrame(overlaySurface, to: bounds)
        }

        switch presentation {
        case .nothing, .overlay:
            break
        case .panes:
            var focusedFrame: CGRect?
            for item in paneItems {
                let frame = scaledRect(item.unitFrame)
                setSurfaceFrame(item.view, to: frame)
                if item.isFocused { focusedFrame = frame }
            }
            for (divider, item) in zip(dividerViews, dividerItems) {
                divider.frame = dividerFrame(for: item)
            }
            if let focusedFrame {
                focusRing.frame = focusedFrame
            }
        }
    }

    private func scaledRect(_ unitRect: CGRect) -> CGRect {
        let raw = CGRect(
            x: unitRect.minX * bounds.width,
            y: unitRect.minY * bounds.height,
            width: unitRect.width * bounds.width,
            height: unitRect.height * bounds.height
        )
        // Pixel-align so Metal surfaces never straddle a device pixel.
        // Aligning each pane's rect independently can open a sub-pixel seam
        // at a boundary; the divider's visible line sits exactly there and
        // covers it.
        return backingAlignedRect(raw, options: .alignAllEdgesNearest)
    }

    private func setSurfaceFrame(_ surfaceView: NSView, to frame: CGRect) {
        guard surfaceView.frame != frame else { return }
        surfaceView.frame = frame
        // Ghostty sizes its grid from the surface's current bounds; poke it
        // after every real change, as reveal-on-selection always has.
        (surfaceView as? TerminalView)?.fitToSize()
    }

    private func dividerFrame(for item: DividerItem) -> CGRect {
        let region = scaledRect(item.unitRegion)
        switch item.axis {
        case .horizontal:
            let x = region.minX + region.width * CGFloat(item.ratio)
            return CGRect(
                x: x - Self.dividerThickness / 2, y: region.minY,
                width: Self.dividerThickness, height: region.height
            )
        case .vertical:
            let y = region.minY + region.height * CGFloat(item.ratio)
            return CGRect(
                x: region.minX, y: y - Self.dividerThickness / 2,
                width: region.width, height: Self.dividerThickness
            )
        }
    }

    // MARK: - Click-to-focus

    /// Terminal surfaces consume their own mouseDown (that's how they take
    /// key focus and selection), so the container can't override mouseDown
    /// to learn about pane clicks. A local monitor observes without
    /// consuming: the event continues to the pane for its normal click
    /// handling, and the model's focus follows. Same pattern as
    /// `ShortcutRouter`'s key monitor.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
        } else if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.noteClick(event)
                return event
            }
        }
    }

    private func noteClick(_ event: NSEvent) {
        guard event.window === window, presentationIsPanes, paneItems.count > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // A divider click is a resize, not a focus change.
        guard !dividerViews.contains(where: { !$0.isHidden && $0.frame.contains(point) }) else {
            return
        }
        guard let clicked = paneItems.first(where: { $0.view.frame.contains(point) }),
              !clicked.isFocused
        else { return }
        onFocusPane?(clicked.paneID)
    }
}

/// The grabbable boundary between two panes: a hairline drawn at its center
/// with transparent hit padding on both sides. Reports drag positions in the
/// superview's coordinate space; all ratio math stays in the container.
@MainActor
final class PaneDividerView: NSView {
    enum DragPhase {
        case began, moved, ended
    }

    var axis: SplitAxis = .horizontal {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onDrag: ((NSPoint, DragPhase) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line: NSRect
        switch axis {
        case .horizontal:
            line = NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
        case .vertical:
            line = NSRect(x: bounds.minX, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        }
        line.intersection(dirtyRect).fill()
    }

    override func resetCursorRects() {
        addCursorRect(
            bounds,
            cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        )
    }

    override func mouseDown(with event: NSEvent) {
        report(event, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        report(event, .moved)
    }

    override func mouseUp(with event: NSEvent) {
        report(event, .ended)
    }

    private func report(_ event: NSEvent, _ phase: DragPhase) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil), phase)
    }
}

/// Minimal visual indication of the focused pane: a thin accent border laid
/// over its edges. Never interactive — hit testing passes straight through
/// to the terminal underneath.
@MainActor
private final class PaneFocusRingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateLayer() {
        // The asset-catalog accent (Theme.accent's backing color), resolved
        // per appearance here since layer colors don't auto-follow. Falls
        // back to the system accent if the asset ever goes missing.
        let accent = NSColor(named: "AccentColor") ?? .controlAccentColor
        layer?.borderColor = accent.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
