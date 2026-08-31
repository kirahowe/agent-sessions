import CoreGraphics
import Foundation

/// The functional core of split panes: a session's pane arrangement as a
/// small binary tree, with pure operations for splitting, closing, resizing,
/// and focus movement. No AppKit anywhere — every geometry question is
/// answered in an abstract rect space so the whole model is unit-testable
/// without views. `TerminalCenter` owns one `SessionPaneLayout` per session
/// (the imperative shell); the view layer turns `paneFrames`/`dividers` into
/// real subview frames.
///
/// Geometry convention: all frames returned by this file have the origin at
/// the TOP-left with y increasing DOWNWARD — `.vertical` splits put `first`
/// above `second`, and `FocusDirection.down` means larger y. The container
/// view that consumes these frames is flipped (`isFlipped = true`) to match;
/// if that ever changes, this convention — not each call site — is the thing
/// to revisit.

/// Which way a split divides its region. Named for the axis along which the
/// two children are laid out, not the divider's direction.
enum SplitAxis: Equatable {
    /// Children sit side by side: `first` left, `second` right ("split right").
    case horizontal
    /// Children stack: `first` on top, `second` below ("split down").
    case vertical
}

enum FocusDirection: Equatable {
    case left, right, up, down
}

/// One step of a path from the root of a `PaneTree` to a node: which child
/// of a split to descend into. A full `[PaneBranch]` addresses a split node
/// (for `dividers`/`resizing`); paths are recomputed from the tree on every
/// layout pass rather than stored, so they can never go stale.
enum PaneBranch: Equatable {
    case first, second
}

/// The tree itself: a leaf is a pane (stable UUID for the life of the pane);
/// an interior node is a split with an orientation and a ratio giving
/// `first`'s share of the region.
indirect enum PaneTree: Equatable {
    case leaf(UUID)
    case split(axis: SplitAxis, ratio: Double, first: PaneTree, second: PaneTree)

    /// Hard bounds on any split ratio. The view layer may clamp tighter
    /// (e.g. to a minimum pixel size); this floor only guarantees no pane
    /// can be resized into invisibility through the model alone.
    static let ratioRange: ClosedRange<Double> = 0.1...0.9

    /// Every pane id, in in-order (left-to-right / top-to-bottom) traversal
    /// order. The first element of a subtree is what inherits focus when a
    /// sibling collapses into it — see `SessionPaneLayout.removePane`.
    var paneIDs: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.paneIDs + second.paneIDs
        }
    }

    func contains(_ pane: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == pane
        case .split(_, _, let first, let second):
            return first.contains(pane) || second.contains(pane)
        }
    }

    /// The tree with `pane`'s leaf replaced by a split holding the old pane
    /// and `newPane` at an even ratio; `first` is always the existing pane,
    /// so a split reads as "the new pane appears right of / below the one
    /// that was split." Nil when `pane` is not in the tree.
    func splitting(_ pane: UUID, axis: SplitAxis, adding newPane: UUID) -> PaneTree? {
        switch self {
        case .leaf(let id):
            guard id == pane else { return nil }
            return .split(axis: axis, ratio: 0.5, first: .leaf(id), second: .leaf(newPane))
        case .split(let existingAxis, let ratio, let first, let second):
            if let newFirst = first.splitting(pane, axis: axis, adding: newPane) {
                return .split(axis: existingAxis, ratio: ratio, first: newFirst, second: second)
            }
            if let newSecond = second.splitting(pane, axis: axis, adding: newPane) {
                return .split(axis: existingAxis, ratio: ratio, first: first, second: newSecond)
            }
            return nil
        }
    }

    enum Removal: Equatable {
        /// `pane` is not in this tree; nothing changed.
        case notFound
        /// `pane` was the only leaf; the tree is now empty.
        case empty
        /// The remaining tree: the removed leaf's parent split collapsed to
        /// the sibling subtree, which inherits the whole region.
        case tree(PaneTree)
    }

    /// The tree without `pane`. Removing one child of a split collapses the
    /// split to its other child — a region is never left owned by a
    /// single-child interior node.
    func removing(_ pane: UUID) -> Removal {
        switch self {
        case .leaf(let id):
            return id == pane ? .empty : .notFound
        case .split(let axis, let ratio, let first, let second):
            switch first.removing(pane) {
            case .empty:
                return .tree(second)
            case .tree(let newFirst):
                return .tree(.split(axis: axis, ratio: ratio, first: newFirst, second: second))
            case .notFound:
                break
            }
            switch second.removing(pane) {
            case .empty:
                return .tree(first)
            case .tree(let newSecond):
                return .tree(.split(axis: axis, ratio: ratio, first: first, second: newSecond))
            case .notFound:
                return .notFound
            }
        }
    }

    /// The subtree that would inherit `pane`'s region if it were removed —
    /// the other child of its parent split. Nil for a pane not in the tree
    /// or for the root leaf (nothing inherits from the last pane).
    func sibling(of pane: UUID) -> PaneTree? {
        switch self {
        case .leaf:
            return nil
        case .split(_, _, let first, let second):
            if case .leaf(let id) = first, id == pane { return second }
            if case .leaf(let id) = second, id == pane { return first }
            return first.sibling(of: pane) ?? second.sibling(of: pane)
        }
    }

    /// The tree with the split node addressed by `path` set to `ratio`
    /// (clamped to `ratioRange`). A path that does not land on a split —
    /// stale after a concurrent close, say — returns the tree unchanged:
    /// resizing is a cosmetic operation and must never invent structure.
    func resizing(dividerAt path: [PaneBranch], to ratio: Double) -> PaneTree {
        guard case .split(let axis, let currentRatio, let first, let second) = self else {
            return self
        }
        guard let step = path.first else {
            let clamped = min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
            return .split(axis: axis, ratio: clamped, first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        switch step {
        case .first:
            return .split(
                axis: axis, ratio: currentRatio,
                first: first.resizing(dividerAt: rest, to: ratio), second: second
            )
        case .second:
            return .split(
                axis: axis, ratio: currentRatio,
                first: first, second: second.resizing(dividerAt: rest, to: ratio)
            )
        }
    }

    /// Each pane's frame within `bounds`, split top-left origin, y-down (see
    /// the file header). Pane frames tile `bounds` exactly; the view layer
    /// carves its divider hit areas out of the panes' edges rather than this
    /// model reserving divider space, so the model stays free of any pixel
    /// constant.
    func paneFrames(in bounds: CGRect) -> [UUID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: bounds]
        case .split(let axis, let ratio, let first, let second):
            let (firstBounds, secondBounds) = Self.divide(bounds, axis: axis, ratio: ratio)
            // Leaf UUIDs are unique by construction, so the merge closure is
            // unreachable; keeping the existing value is the arbitrary choice.
            return first.paneFrames(in: firstBounds)
                .merging(second.paneFrames(in: secondBounds)) { existing, _ in existing }
        }
    }

    /// One divider per split node: everything the view layer needs to draw
    /// the boundary and turn a drag into a `resizing` call.
    struct Divider: Equatable {
        /// Path from the root to this divider's split node — pass back to
        /// `resizing(dividerAt:to:)`.
        let path: [PaneBranch]
        let axis: SplitAxis
        /// The split node's whole region, in the same space as `paneFrames`.
        /// A drag position converts to a new ratio against this region:
        /// `(x - region.minX) / region.width` for a horizontal split.
        let region: CGRect
        let ratio: Double

        /// The boundary line between the split's children: zero-thickness,
        /// spanning the region across the split axis. The view layer
        /// thickens it into a grabbable strip.
        var line: CGRect {
            switch axis {
            case .horizontal:
                let x = region.minX + region.width * CGFloat(ratio)
                return CGRect(x: x, y: region.minY, width: 0, height: region.height)
            case .vertical:
                let y = region.minY + region.height * CGFloat(ratio)
                return CGRect(x: region.minX, y: y, width: region.width, height: 0)
            }
        }
    }

    /// Every divider in the tree, with regions computed within `bounds`.
    func dividers(in bounds: CGRect, path: [PaneBranch] = []) -> [Divider] {
        guard case .split(let axis, let ratio, let first, let second) = self else {
            return []
        }
        let (firstBounds, secondBounds) = Self.divide(bounds, axis: axis, ratio: ratio)
        return [Divider(path: path, axis: axis, region: bounds, ratio: ratio)]
            + first.dividers(in: firstBounds, path: path + [.first])
            + second.dividers(in: secondBounds, path: path + [.second])
    }

    /// The pane you land on moving from `pane` toward `direction`, or nil at
    /// an edge (or for an unknown pane). Chosen by geometry, not tree
    /// structure: the nearest pane past the source's edge in that direction,
    /// preferring the one with the most perpendicular overlap with the
    /// source — i.e. the pane a user would point at. Computed in the unit
    /// square, so the answer is independent of the view's actual size.
    func paneID(inDirection direction: FocusDirection, from pane: UUID) -> UUID? {
        let frames = paneFrames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let source = frames[pane] else { return nil }
        // Tolerance for accumulated floating-point error in nested ratio
        // multiplication — adjacent frames can miss "exactly adjacent" by an
        // ulp or two, never by anything near this.
        let epsilon: CGFloat = 1e-9

        struct Candidate {
            let id: UUID
            let distance: CGFloat
            let overlap: CGFloat
            let frame: CGRect
        }

        let candidates: [Candidate] = frames.compactMap { id, frame in
            guard id != pane else { return nil }
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                distance = source.minX - frame.maxX
                overlap = Self.overlapLength(source.minY...source.maxY, frame.minY...frame.maxY)
            case .right:
                distance = frame.minX - source.maxX
                overlap = Self.overlapLength(source.minY...source.maxY, frame.minY...frame.maxY)
            case .up:
                distance = source.minY - frame.maxY
                overlap = Self.overlapLength(source.minX...source.maxX, frame.minX...frame.maxX)
            case .down:
                distance = frame.minY - source.maxY
                overlap = Self.overlapLength(source.minX...source.maxX, frame.minX...frame.maxX)
            }
            guard distance >= -epsilon, overlap > epsilon else { return nil }
            return Candidate(id: id, distance: distance, overlap: overlap, frame: frame)
        }

        return candidates.min { a, b in
            if abs(a.distance - b.distance) > epsilon { return a.distance < b.distance }
            if abs(a.overlap - b.overlap) > epsilon { return a.overlap > b.overlap }
            // Full tie (symmetric layouts, e.g. moving right from a full-
            // height pane into an evenly split column): topmost wins, then
            // leftmost — the pane a user would predict, and deterministic
            // across sessions in a way pane-id ordering would not be. Two
            // distinct panes can't share both corners, so this is total.
            if abs(a.frame.minY - b.frame.minY) > epsilon { return a.frame.minY < b.frame.minY }
            return a.frame.minX < b.frame.minX
        }?.id
    }

    // MARK: - Geometry helpers

    private static func divide(_ bounds: CGRect, axis: SplitAxis, ratio: Double) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let firstWidth = bounds.width * CGFloat(ratio)
            let first = CGRect(x: bounds.minX, y: bounds.minY, width: firstWidth, height: bounds.height)
            let second = CGRect(
                x: bounds.minX + firstWidth, y: bounds.minY,
                width: bounds.width - firstWidth, height: bounds.height
            )
            return (first, second)
        case .vertical:
            let firstHeight = bounds.height * CGFloat(ratio)
            let first = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: firstHeight)
            let second = CGRect(
                x: bounds.minX, y: bounds.minY + firstHeight,
                width: bounds.width, height: bounds.height - firstHeight
            )
            return (first, second)
        }
    }

    private static func overlapLength(
        _ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>
    ) -> CGFloat {
        min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound)
    }
}

/// One session's pane state: the tree plus which pane is focused and which
/// was the session's first. Still a pure value — `TerminalCenter` holds one
/// per session and every mutation is copy-in/copy-out.
struct SessionPaneLayout: Equatable {
    private(set) var tree: PaneTree
    private(set) var focusedPane: UUID
    /// The pane the session started with. Only this pane ever prints the
    /// resume hint; it has no other privileges (it can be closed like any
    /// other, and focus policy does not prefer it).
    let initialPane: UUID

    /// Incremented on every STRUCTURAL change — split or removal — and
    /// never on resize or focus. A divider path is a structural position,
    /// not an identity: collapsing an unrelated node can leave a stale path
    /// valid but addressing a different split (remove the left pane of
    /// `A | (B / (C | D))` and the old `[.second]` now names `C | D`). A
    /// drag captures this counter with the path and drops the event when
    /// they no longer match, so a pane exiting mid-drag can never make the
    /// drag resize a split the user isn't holding.
    private(set) var structureGeneration = 0

    init(initialPane: UUID) {
        self.initialPane = initialPane
        self.tree = .leaf(initialPane)
        self.focusedPane = initialPane
    }

    var paneIDs: [UUID] { tree.paneIDs }
    var paneCount: Int { tree.paneIDs.count }

    /// Splits the focused pane, adding `newPane` beside/below it. The new
    /// pane takes focus — matching every terminal splitter, where a split is
    /// a request to start working in the new pane.
    mutating func splitFocused(axis: SplitAxis, adding newPane: UUID) {
        guard let newTree = tree.splitting(focusedPane, axis: axis, adding: newPane) else {
            // Unreachable while the focus invariant holds (focusedPane is
            // always in the tree); refusing is safer than trapping.
            return
        }
        tree = newTree
        focusedPane = newPane
        structureGeneration += 1
    }

    enum RemoveOutcome: Equatable {
        case notFound
        /// The pane was removed; the session keeps its remaining panes.
        case removed
        /// The pane was the session's last — the caller owns what "the
        /// session is now paneless" means (row teardown); the layout value
        /// itself is no longer meaningful and should be discarded.
        case lastPane
    }

    /// Removes `pane` from the tree. If the focused pane is removed, focus
    /// moves to the first leaf (in traversal order) of the subtree that
    /// inherits the freed region — the pane whose space grows is the pane
    /// the user is now implicitly looking at.
    mutating func removePane(_ pane: UUID) -> RemoveOutcome {
        // Capture the heir before mutating: sibling(of:) answers against the
        // tree that still contains the pane.
        let heir = tree.sibling(of: pane)?.paneIDs.first
        switch tree.removing(pane) {
        case .notFound:
            return .notFound
        case .empty:
            return .lastPane
        case .tree(let remaining):
            tree = remaining
            if focusedPane == pane {
                focusedPane = heir ?? remaining.paneIDs[0]
            }
            structureGeneration += 1
            return .removed
        }
    }

    /// Moves focus to `pane` if it exists. Returns whether it did.
    @discardableResult
    mutating func focus(_ pane: UUID) -> Bool {
        guard tree.contains(pane) else { return false }
        focusedPane = pane
        return true
    }

    /// Moves focus one pane toward `direction`. Returns whether focus moved
    /// (false at an edge, so the caller can pass the key on or beep).
    @discardableResult
    mutating func moveFocus(_ direction: FocusDirection) -> Bool {
        guard let target = tree.paneID(inDirection: direction, from: focusedPane) else {
            return false
        }
        focusedPane = target
        return true
    }

    /// Sets the ratio of the split addressed by `path` — see
    /// `PaneTree.resizing(dividerAt:to:)`.
    mutating func setRatio(at path: [PaneBranch], to ratio: Double) {
        tree = tree.resizing(dividerAt: path, to: ratio)
    }
}
