import CoreGraphics
import Foundation
import XCTest
@testable import Agents

/// Coverage of `PaneTree` and `SessionPaneLayout` against the contracts
/// documented on each function in `PaneLayout.swift` and the "Native split
/// panes" / "Testing" sections of `design/scoped-reviews-and-splits.md`. Both
/// types are Foundation/CoreGraphics-only pure values — no AppKit, no
/// `@MainActor`, no store or terminal machinery, same spirit as
/// `SessionAttentionTests` for the attention reducer.
final class PaneLayoutTests: XCTestCase {

    // MARK: - Test helpers

    /// Approximate `CGRect` comparison for frames derived from a ratio that
    /// isn't exactly representable in binary floating point (e.g. 0.3, 0.4,
    /// 0.7). Exact ratios (0.5) are compared with plain `XCTAssertEqual`
    /// instead, since the arithmetic involved is bit-exact.
    private func assertRectEqual(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, message, file: file, line: line)
    }

    /// The layout used across the `paneID(inDirection:from:)` tests: "split
    /// right, then split the right pane down" — a left pane spanning the
    /// full height, a top-right pane, and a bottom-right pane.
    private func makeLeftTopRightBottomRightLayout() -> (tree: PaneTree, left: UUID, topRight: UUID, bottomRight: UUID) {
        let left = UUID()
        let topRight = UUID()
        let bottomRight = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(left),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(topRight), second: .leaf(bottomRight))
        )
        return (tree, left, topRight, bottomRight)
    }

    // MARK: - 1. PaneTree basics

    func test_paneIDs_singleLeaf_isThatOnePane() {
        let id = UUID()
        XCTAssertEqual(PaneTree.leaf(id).paneIDs, [id], "a lone leaf's paneIDs must be exactly itself")
    }

    func test_paneIDs_inOrderTraversal_nestedTree() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(c), second: .leaf(d))
        )

        XCTAssertEqual(tree.paneIDs, [a, b, c, d], "paneIDs must walk the tree left-to-right / top-to-bottom in traversal order — removePane's focus-heir logic depends on element 0 being whichever leaf a user would actually see first, not just any leaf of the subtree")
    }

    func test_contains_trueForPresentPane_falseForUnknownPane() {
        let a = UUID(); let b = UUID(); let unknown = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        XCTAssertTrue(tree.contains(a))
        XCTAssertTrue(tree.contains(b))
        XCTAssertFalse(tree.contains(unknown), "contains must not report true for a pane id that was never inserted into the tree")
    }

    // MARK: - 2. splitting(_:axis:adding:)

    func test_splitting_replacesLeaf_evenRatio_existingFirstNewSecond() {
        let existing = UUID()
        let new = UUID()

        let result = PaneTree.leaf(existing).splitting(existing, axis: .horizontal, adding: new)

        XCTAssertEqual(
            result, .split(axis: .horizontal, ratio: 0.5, first: .leaf(existing), second: .leaf(new)),
            "splitting must put the EXISTING pane in `first` and the new pane in `second` at an even 0.5 ratio — reversing that order would mean every split silently repositions the pane the user was already working in"
        )
    }

    func test_splitting_nestedTree_onlyTouchesTargetLeaf() {
        let a = UUID(); let b = UUID(); let c = UUID(); let new = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )

        let result = tree.splitting(b, axis: .horizontal, adding: new)

        let expected = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(
                axis: .vertical, ratio: 0.5,
                first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(new)),
                second: .leaf(c)
            )
        )
        XCTAssertEqual(result, expected, "splitting a leaf deep in the tree must rebuild only the path down to that leaf — pane a, pane c, and every untouched split's axis and ratio must survive completely unchanged")
    }

    func test_splitting_unknownPane_returnsNil() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        XCTAssertNil(tree.splitting(UUID(), axis: .horizontal, adding: UUID()), "splitting a pane id that isn't in the tree must fail rather than silently doing nothing or splitting the wrong pane")
    }

    // MARK: - 3. removing(_:)

    func test_removing_collapsesToSibling_whenFirstChildRemoved() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        XCTAssertEqual(tree.removing(a), .tree(.leaf(b)), "removing the first child of a two-pane split must collapse the whole split down to the surviving second child")
    }

    func test_removing_collapsesToSibling_whenSecondChildRemoved() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        XCTAssertEqual(tree.removing(b), .tree(.leaf(a)), "removing the second child of a two-pane split must collapse the whole split down to the surviving first child")
    }

    func test_removing_nestedTree_collapsesOnlyRightNode_preservesSurroundingStructureAndRatios() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.3,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.7, first: .leaf(b), second: .leaf(c))
        )

        let result = tree.removing(c)

        XCTAssertEqual(
            result, .tree(.split(axis: .horizontal, ratio: 0.3, first: .leaf(a), second: .leaf(b))),
            "removing c must collapse only the inner vertical split down to b, leaving the outer horizontal split's axis and 0.3 ratio completely untouched — a removal that rebuilds ratios along the way would silently resize a's region for no reason"
        )
    }

    func test_removing_onlyLeaf_returnsEmpty() {
        let a = UUID()
        XCTAssertEqual(PaneTree.leaf(a).removing(a), .empty, "removing the tree's only leaf must report .empty, not a tree containing nothing")
    }

    func test_removing_unknownPane_returnsNotFound_treeUnchanged() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        let result = tree.removing(UUID())

        XCTAssertEqual(result, .notFound, "removing a pane id absent from the tree must be reported distinctly from an ordinary successful removal, or a caller could mistake a no-op for having actually closed a pane")
    }

    // MARK: - 4. sibling(of:)

    func test_sibling_directChildren_eachReturnsTheOther() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        XCTAssertEqual(tree.sibling(of: a), .leaf(b))
        XCTAssertEqual(tree.sibling(of: b), .leaf(a))
    }

    func test_sibling_deepPane_returnsWholeInheritingSubtree() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let inner = PaneTree.split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: inner, second: .leaf(c))

        XCTAssertEqual(tree.sibling(of: a), .leaf(b), "a's sibling within the inner split is just leaf b")
        XCTAssertEqual(tree.sibling(of: c), inner, "c's sibling at the root is the ENTIRE inner split subtree, not just one leaf of it — this is the subtree that must inherit c's region if c were removed, and removePane's focus policy depends on being able to read its first leaf")
    }

    func test_sibling_nilForRootLeaf() {
        let a = UUID()
        XCTAssertNil(PaneTree.leaf(a).sibling(of: a), "a lone root leaf has no sibling — nothing inherits when the last pane goes away")
    }

    func test_sibling_nilForUnknownPane() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        XCTAssertNil(tree.sibling(of: UUID()), "asking for the sibling of a pane that isn't in the tree must return nil, not a wrong-but-present answer")
    }

    // MARK: - 5. resizing(dividerAt:to:)

    func test_resizing_rootPath_setsRatioDirectly() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        let resized = tree.resizing(dividerAt: [], to: 0.7)

        XCTAssertEqual(resized, .split(axis: .horizontal, ratio: 0.7, first: .leaf(a), second: .leaf(b)), "an empty path must address the root split itself")
    }

    func test_resizing_nestedPath_setsOnlyTargetSplitRatio() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )

        let resized = tree.resizing(dividerAt: [.second], to: 0.3)

        let expected = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.3, first: .leaf(b), second: .leaf(c))
        )
        XCTAssertEqual(resized, expected, "a [.second] path must resize only the nested split it addresses — the outer split's 0.5 ratio must be left exactly as it was, or dragging one divider would silently move an unrelated one elsewhere in the tree")
    }

    func test_resizing_clampsBelowRange() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        let resized = tree.resizing(dividerAt: [], to: -3)

        XCTAssertEqual(
            resized, .split(axis: .horizontal, ratio: PaneTree.ratioRange.lowerBound, first: .leaf(a), second: .leaf(b)),
            "a ratio below the floor must clamp to ratioRange's lower bound (0.1), never pass through raw — an unclamped negative ratio would hand the view layer a pane with negative width"
        )
    }

    func test_resizing_clampsAboveRange() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        let resized = tree.resizing(dividerAt: [], to: 5)

        XCTAssertEqual(
            resized, .split(axis: .horizontal, ratio: PaneTree.ratioRange.upperBound, first: .leaf(a), second: .leaf(b)),
            "a ratio above the ceiling must clamp to ratioRange's upper bound (0.9), so a runaway drag can never resize a pane out of existence"
        )
    }

    func test_resizing_pathIntoLeaf_returnsTreeUnchanged() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        // `a` is a leaf, so a path that steps into it and then keeps going is
        // stale — as if the divider it once addressed already closed.
        let resized = tree.resizing(dividerAt: [.first, .second], to: 0.8)

        XCTAssertEqual(resized, tree, "a path that runs into a leaf and continues past it must leave the whole tree bit-for-bit unchanged — resizing must never invent structure to satisfy a stale path, e.g. after a concurrent close")
    }

    func test_resizing_pathDeeperThanTree_returnsTreeUnchanged() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )

        let resized = tree.resizing(dividerAt: [.second, .first, .second, .first], to: 0.8)

        XCTAssertEqual(resized, tree, "a path far deeper than the tree's actual depth must be a no-op, the same as any other stale path")
    }

    // MARK: - 6. paneFrames(in:)

    func test_paneFrames_singleLeaf_fillsBoundsExactly() {
        let id = UUID()
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 250)

        let frames = PaneTree.leaf(id).paneFrames(in: bounds)

        XCTAssertEqual(frames, [id: bounds], "a single-pane tree must give that pane the entire bounds rect, unchanged")
    }

    func test_paneFrames_horizontalSplit_evenRatio_widthsAndOrigins() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        let frames = tree.paneFrames(in: bounds)

        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 200, height: 300), "first must be the left half")
        XCTAssertEqual(frames[b], CGRect(x: 200, y: 0, width: 200, height: 300), "second must be the right half, starting exactly where first ends")
    }

    func test_paneFrames_verticalSplit_yDown_firstIsTopRegion() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        let frames = tree.paneFrames(in: bounds)

        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 400, height: 150), "in this y-down geometry, first must occupy the TOP region (smaller y), matching the file header's documented convention — getting this backwards would put every new vertical split's first pane visually below its second")
        XCTAssertEqual(frames[b], CGRect(x: 0, y: 150, width: 400, height: 150), "second must be the bottom region")
    }

    func test_paneFrames_nestedSplits_withNonEvenRatios_nestCorrectly() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.4,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.25, first: .leaf(b), second: .leaf(c))
        )
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frames = tree.paneFrames(in: bounds)

        assertRectEqual(frames[a]!, CGRect(x: 0, y: 0, width: 400, height: 800), accuracy: 1e-6, "the left leaf must take exactly 40% of the width and the full height")
        assertRectEqual(frames[b]!, CGRect(x: 400, y: 0, width: 600, height: 200), accuracy: 1e-6, "within the remaining 60%-wide right region, the top nested leaf must take exactly 25% of ITS OWN height, not 25% of the whole bounds — nesting must compose against the child region, not the root")
        assertRectEqual(frames[c]!, CGRect(x: 400, y: 200, width: 600, height: 600), accuracy: 1e-6, "the bottom nested leaf must take the rest of the right region's height, positioned below the top nested leaf")
    }

    func test_paneFrames_tileBoundsExactly_noGapsNoOverlaps() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.4,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.25, first: .leaf(b), second: .leaf(c))
        )
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frames = tree.paneFrames(in: bounds)
        let totalArea = frames.values.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let boundsArea = bounds.width * bounds.height

        XCTAssertEqual(totalArea, boundsArea, accuracy: 1e-3, "the panes' areas must sum to exactly the bounds' area — any less means a gap the user would see as dead unclickable space, any more means panes overlapping and fighting the same pixels")

        let frameA = frames[a]!
        let frameB = frames[b]!
        let frameC = frames[c]!
        XCTAssertEqual(frameA.maxX, frameB.minX, accuracy: 1e-6, "the left pane's right edge must exactly meet the right column's left edge — no seam, no overlap")
        XCTAssertEqual(frameA.maxX, frameC.minX, accuracy: 1e-6, "same for the bottom-right pane's left edge")
        XCTAssertEqual(frameB.maxY, frameC.minY, accuracy: 1e-6, "the top-right pane's bottom edge must exactly meet the bottom-right pane's top edge")
        XCTAssertEqual(frameA.minY, frameB.minY, accuracy: 1e-6, "the tiling must start flush with the top of bounds")
        XCTAssertEqual(frameA.maxY, frameC.maxY, accuracy: 1e-6, "and end flush with the bottom of bounds")
    }

    // MARK: - 7. dividers(in:path:)

    func test_dividers_singleHorizontalSplit_rootPathAxisRegionRatioAndLine() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        let dividers = tree.dividers(in: bounds)

        XCTAssertEqual(dividers.count, 1, "a tree with exactly one split node must produce exactly one divider")
        let divider = dividers[0]
        XCTAssertEqual(divider.path, [], "the root split's divider must carry the empty path, so passing it straight back to resizing(dividerAt:) addresses the root")
        XCTAssertEqual(divider.axis, .horizontal)
        XCTAssertEqual(divider.region, bounds, "the divider's region is the whole split node's region, not either child's half")
        XCTAssertEqual(divider.ratio, 0.5)
        XCTAssertEqual(divider.line, CGRect(x: 200, y: 0, width: 0, height: 300), "a horizontal split's line must be a zero-width vertical segment sitting exactly at the ratio boundary (400 * 0.5 = 200), spanning the region's full height")
    }

    func test_dividers_singleVerticalSplit_lineSitsAtRatioBoundary() {
        let a = UUID(); let b = UUID()
        let tree = PaneTree.split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        let divider = tree.dividers(in: bounds)[0]

        XCTAssertEqual(divider.line, CGRect(x: 0, y: 150, width: 400, height: 0), "a vertical split's line must be a zero-height horizontal segment at the ratio boundary (300 * 0.5 = 150), spanning the region's full width")
    }

    func test_dividers_nestedSplit_carriesNestedPathAndChildRegion() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        let dividers = tree.dividers(in: bounds)

        XCTAssertEqual(dividers.count, 2, "two split nodes must produce exactly two dividers")
        guard let nested = dividers.first(where: { $0.path == [.second] }) else {
            return XCTFail("the nested split under `second` must produce a divider addressed by path [.second]")
        }
        XCTAssertEqual(nested.axis, .vertical)
        XCTAssertEqual(
            nested.region, CGRect(x: 200, y: 0, width: 200, height: 300),
            "a nested divider's region must be its own split node's region within bounds (the right half after the outer split), not the root bounds — otherwise a drag on the nested divider would compute its new ratio against the wrong span"
        )
        XCTAssertEqual(nested.ratio, 0.5)
    }

    func test_dividers_onePerSplitNode_fourLeafTree() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(c), second: .leaf(d))
        )
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)

        let dividers = tree.dividers(in: bounds)

        XCTAssertEqual(dividers.count, 3, "three split nodes (one root, two nested) must produce exactly three dividers, with no divider for a leaf and none doubled up for a split with two leaf children")
        XCTAssertEqual(Set(dividers.map(\.path)), Set([[], [.first], [.second]]), "every split node's own path must appear exactly once among the dividers")
        guard let leftDivider = dividers.first(where: { $0.path == [.first] }) else {
            return XCTFail("missing the [.first] divider")
        }
        guard let rightDivider = dividers.first(where: { $0.path == [.second] }) else {
            return XCTFail("missing the [.second] divider")
        }
        XCTAssertEqual(leftDivider.region, CGRect(x: 0, y: 0, width: 200, height: 200), "the left nested divider's region must be the left half of bounds")
        XCTAssertEqual(rightDivider.region, CGRect(x: 200, y: 0, width: 200, height: 200), "the right nested divider's region must be the right half of bounds")
    }

    func test_dividers_feedingPathBackIntoResizing_changesThatSplitsRatioOnly() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        guard let nestedDivider = tree.dividers(in: bounds).first(where: { $0.path == [.second] }) else {
            return XCTFail("expected a nested divider to feed back into resizing")
        }

        let resized = tree.resizing(dividerAt: nestedDivider.path, to: 0.25)
        let newDividers = resized.dividers(in: bounds)

        guard let newNested = newDividers.first(where: { $0.path == [.second] }) else {
            return XCTFail("the nested divider must still exist after resizing")
        }
        guard let newRoot = newDividers.first(where: { $0.path == [] }) else {
            return XCTFail("the root divider must still exist after resizing")
        }
        XCTAssertEqual(newNested.ratio, 0.25, "a divider's own path, fed straight back into resizing(dividerAt:to:), must change exactly that split's ratio — this is the whole drag-to-resize contract between the view layer and the model")
        XCTAssertEqual(newRoot.ratio, 0.5, "resizing the nested divider must not perturb the unrelated root divider's ratio")
    }

    // MARK: - 8. paneID(inDirection:from:)

    func test_paneID_right_fromLeftPane_fullTiePrefersTopmostPane() {
        let (tree, left, topRight, bottomRight) = makeLeftTopRightBottomRightLayout()
        _ = bottomRight

        // The left pane is equidistant (0) from both right-column panes, and
        // each covers exactly half of the left pane's height, so distance
        // and overlap both tie — the documented tiebreak is positional:
        // topmost wins, which is both deterministic across launches (unlike
        // any pane-id ordering) and the pane a user would predict.
        XCTAssertEqual(
            tree.paneID(inDirection: .right, from: left), topRight,
            "a full distance-and-overlap tie must resolve to the TOPMOST candidate — an id-based tiebreak would make the same keystroke land on a different pane from one launch to the next"
        )
    }

    func test_paneID_down_fromTopRight_isBottomRight() {
        let (tree, _, topRight, bottomRight) = makeLeftTopRightBottomRightLayout()
        XCTAssertEqual(tree.paneID(inDirection: .down, from: topRight), bottomRight, "pressing down from the top-right pane must land on the bottom-right pane directly below it")
    }

    func test_paneID_up_fromBottomRight_isTopRight() {
        let (tree, _, topRight, bottomRight) = makeLeftTopRightBottomRightLayout()
        XCTAssertEqual(tree.paneID(inDirection: .up, from: bottomRight), topRight, "pressing up from the bottom-right pane must land on the top-right pane directly above it")
    }

    func test_paneID_left_fromTopRight_isLeftPane() {
        let (tree, left, topRight, _) = makeLeftTopRightBottomRightLayout()
        XCTAssertEqual(tree.paneID(inDirection: .left, from: topRight), left, "pressing left from the top-right pane must land on the left pane, its only neighbor in that direction")
    }

    func test_paneID_atEdges_returnsNil() {
        let (tree, left, topRight, bottomRight) = makeLeftTopRightBottomRightLayout()

        XCTAssertNil(tree.paneID(inDirection: .left, from: left), "the left pane spans the whole left column with nothing further left of it — moving left must refuse rather than invent a target")
        XCTAssertNil(tree.paneID(inDirection: .up, from: left), "the left pane spans the full height, so there is nothing above it to move to")
        XCTAssertNil(tree.paneID(inDirection: .down, from: left), "the left pane spans the full height, so there is nothing below it to move to either")
        XCTAssertNil(tree.paneID(inDirection: .up, from: topRight), "the top-right pane is already at the top edge — moving up must refuse")
        XCTAssertNil(tree.paneID(inDirection: .down, from: bottomRight), "the bottom-right pane is already at the bottom edge — moving down must refuse")
        XCTAssertNil(tree.paneID(inDirection: .right, from: topRight), "the top-right pane is already at the right edge — moving right must refuse")
        XCTAssertNil(tree.paneID(inDirection: .right, from: bottomRight), "the bottom-right pane is already at the right edge too")
    }

    func test_paneID_unknownSourcePane_returnsNil() {
        let (tree, _, _, _) = makeLeftTopRightBottomRightLayout()
        XCTAssertNil(tree.paneID(inDirection: .right, from: UUID()), "a pane id that isn't in the tree at all has no frame to compute a direction from, so the query must refuse rather than crash or guess")
    }

    func test_paneID_prefersLargestPerpendicularOverlap_onDistanceTie() {
        let top = UUID()
        let bottom = UUID()
        let right = UUID()
        // Left column: a tall top pane (70%) over a short bottom pane (30%).
        // Right column: one pane spanning the full height.
        let tree = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.7, first: .leaf(top), second: .leaf(bottom)),
            second: .leaf(right)
        )

        // Both left-column panes are equidistant from `right` (they share
        // its left edge exactly), so the tiebreak must fall to whichever one
        // the user's eye would actually land on: the one with more vertical
        // overlap against the source pane's full-height span. That's the
        // tall top pane.
        let first = tree.paneID(inDirection: .left, from: right)
        XCTAssertEqual(first, top, "moving left from a full-height pane toward two stacked panes at equal distance must prefer the one with more overlap against its height — here the tall top pane covers 70% of the source's height against the short pane's 30%")

        let second = tree.paneID(inDirection: .left, from: right)
        XCTAssertEqual(first, second, "the overlap-based choice must be stable across repeated calls with no change to the layout")
    }

    // MARK: - 9. SessionPaneLayout

    func test_init_isSingleLeafTreeFocusedOnInitialPane() {
        let p0 = UUID()
        let layout = SessionPaneLayout(initialPane: p0)

        XCTAssertEqual(layout.tree, .leaf(p0))
        XCTAssertEqual(layout.focusedPane, p0)
        XCTAssertEqual(layout.initialPane, p0)
        XCTAssertEqual(layout.paneIDs, [p0])
        XCTAssertEqual(layout.paneCount, 1)
    }

    func test_splitFocused_focusesNewPane_andSplitsThePreviouslyFocusedPane() {
        let p0 = UUID(); let p1 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)

        layout.splitFocused(axis: .horizontal, adding: p1)

        XCTAssertEqual(layout.tree, .split(axis: .horizontal, ratio: 0.5, first: .leaf(p0), second: .leaf(p1)), "splitting the focused (and only) pane must replace it with a horizontal split holding the old pane first and the new pane second")
        XCTAssertEqual(layout.focusedPane, p1, "a split is a request to start working in the new pane — focus must move there immediately, or the user would type into the pane they just split away from instead of the one they just opened")
    }

    func test_splitFocused_secondSplit_splitsWhicheverPaneIsCurrentlyFocused() {
        let p0 = UUID(); let p1 = UUID(); let p2 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1) // focus -> p1

        layout.splitFocused(axis: .vertical, adding: p2)

        let expected = PaneTree.split(
            axis: .horizontal, ratio: 0.5,
            first: .leaf(p0),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(p1), second: .leaf(p2))
        )
        XCTAssertEqual(expected, layout.tree, "the second split must split p1 — the currently focused pane — not p0, which was only ever focused before the first split")
        XCTAssertEqual(layout.focusedPane, p2)
    }

    func test_removePane_removingAKnownNonLastPane_returnsRemoved() {
        let p0 = UUID(); let p1 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1)

        let outcome = layout.removePane(p0)

        XCTAssertEqual(outcome, .removed, "removing one of two panes must report .removed, not .lastPane — the session still has a pane left")
        XCTAssertEqual(layout.tree, .leaf(p1), "removing p0 must collapse the split down to the surviving leaf")
        XCTAssertFalse(layout.paneIDs.contains(p0), "the removed pane must no longer appear anywhere in the layout")
    }

    func test_removePane_removingTheOnlyPane_returnsLastPane() {
        let p0 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)

        let outcome = layout.removePane(p0)

        XCTAssertEqual(outcome, .lastPane, "removing a session's only remaining pane must report .lastPane so the caller knows to tear down the whole session row through terminalDidClose, not just refresh a layout that no longer means anything")
    }

    func test_removePane_removingUnknownPane_returnsNotFound() {
        let p0 = UUID(); let p1 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1)
        let treeBefore = layout.tree
        let focusBefore = layout.focusedPane

        let outcome = layout.removePane(UUID())

        XCTAssertEqual(outcome, .notFound, "removing a pane id that was never in the tree must be reported distinctly from an ordinary removal")
        XCTAssertEqual(layout.tree, treeBefore, "a not-found removal must not alter the tree")
        XCTAssertEqual(layout.focusedPane, focusBefore, "a not-found removal must not alter focus")
    }

    func test_removePane_focusPolicy_focusedPaneRemoved_focusMovesToFirstLeafOfInheritingSplitSubtree() {
        let p0 = UUID(); let p1 = UUID(); let p2 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1) // tree: p0 | p1, focus p1
        layout.focus(p0)
        layout.splitFocused(axis: .vertical, adding: p2) // splits p0 into p0(top)/p2(bottom); focus p2
        layout.focus(p1) // move focus back to the right pane before removing it

        let outcome = layout.removePane(p1)

        XCTAssertEqual(outcome, .removed)
        // p1's sibling — the whole left subtree — inherits the region. That
        // subtree is itself a split (p0 over p2), so focus must land on the
        // FIRST leaf of it in traversal order, i.e. p0, not p2 just because
        // p2 happened to be focused most recently within that subtree.
        XCTAssertEqual(layout.focusedPane, p0, "when the focused pane is removed and its sibling is itself a split, focus must move to the first leaf (in traversal order) of that inheriting subtree — the pane whose space just grew — not to whichever leaf happens to still exist")
        XCTAssertEqual(layout.tree, .split(axis: .vertical, ratio: 0.5, first: .leaf(p0), second: .leaf(p2)), "removing p1 must collapse the root split down to its sibling subtree wholesale, preserving that subtree's own split intact")
    }

    func test_removePane_removingAnUnfocusedPane_leavesFocusAlone() {
        let p0 = UUID(); let p1 = UUID(); let p2 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1) // focus p1
        layout.focus(p0)
        layout.splitFocused(axis: .vertical, adding: p2) // splits p0; focus p2

        let outcome = layout.removePane(p1) // p1 is not focused (p2 is)

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(layout.focusedPane, p2, "removing a pane the user isn't even looking at must never move focus out from under them")
    }

    func test_focus_rejectsUnknownPane_leavesFocusUnchanged() {
        let p0 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)

        let didFocus = layout.focus(UUID())

        XCTAssertFalse(didFocus, "focusing a pane id that doesn't exist must report failure so callers can't silently point focus at nothing")
        XCTAssertEqual(layout.focusedPane, p0, "a rejected focus request must leave the previous focus intact")
    }

    func test_focus_movesToKnownPane() {
        let p0 = UUID(); let p1 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1) // focus p1

        let didFocus = layout.focus(p0)

        XCTAssertTrue(didFocus)
        XCTAssertEqual(layout.focusedPane, p0)
    }

    func test_moveFocus_atEdge_returnsFalse_andLeavesFocusUnchanged() {
        let p0 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)

        let moved = layout.moveFocus(.right)

        XCTAssertFalse(moved, "a single-pane session has nowhere to move focus to — moveFocus must say so, so the caller can pass the key through or beep, rather than silently no-op-ing in a way indistinguishable from success")
        XCTAssertEqual(layout.focusedPane, p0)
    }

    func test_moveFocus_towardNeighbor_returnsTrue_andUpdatesFocus() {
        let p0 = UUID(); let p1 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1) // p0 | p1, focus p1

        let moved = layout.moveFocus(.left)

        XCTAssertTrue(moved)
        XCTAssertEqual(layout.focusedPane, p0, "moving left from the right pane in a two-pane horizontal split must land focus on the left pane")
    }

    func test_setRatio_routesThroughToTree() {
        let p0 = UUID(); let p1 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        layout.splitFocused(axis: .horizontal, adding: p1)

        layout.setRatio(at: [], to: 0.3)

        guard case .split(_, let ratio, _, _) = layout.tree else {
            return XCTFail("setRatio must not change the tree's shape, only a ratio within it")
        }
        XCTAssertEqual(ratio, 0.3, "setRatio(at:to:) must route straight through to PaneTree.resizing(dividerAt:to:) on the underlying tree")
    }

    func test_structureGeneration_bumpsOnSplitAndRemoval_notOnResizeOrFocus() {
        let p0 = UUID(); let p1 = UUID()
        var layout = SessionPaneLayout(initialPane: p0)
        let initial = layout.structureGeneration

        layout.splitFocused(axis: .horizontal, adding: p1)
        XCTAssertEqual(layout.structureGeneration, initial + 1, "a split changes which split node every path addresses — the generation must advance so in-flight divider drags captured against the old structure are dropped")

        layout.setRatio(at: [], to: 0.3)
        layout.focus(p0)
        XCTAssertEqual(layout.structureGeneration, initial + 1, "resize and focus reshape nothing — bumping the generation for them would cancel the very drag that is producing the resizes")

        _ = layout.removePane(p0)
        XCTAssertEqual(layout.structureGeneration, initial + 2, "a removal collapses a node, which can retarget a previously valid path (remove the left pane of A | (B / (C | D)) and the old [.second] suddenly names C | D) — exactly the change the generation exists to detect")

        _ = layout.removePane(UUID())
        XCTAssertEqual(layout.structureGeneration, initial + 2, "a not-found removal changed nothing, so it must not invalidate live drags")
    }

    // MARK: - 10. Invariants across mixed operation sequences

    /// A fixed, deterministic sequence of ~20 splits and removals (never a
    /// true random source, so a failure always reproduces identically) that
    /// exercises both the focused pane and other panes as removal targets.
    /// After every single step, `focusedPane` must still be a real pane in
    /// the tree and `paneIDs` must contain no duplicates — if either ever
    /// slipped, the app would end up pointing focus at a pane that no
    /// longer exists, or the sidebar could confuse two different panes for
    /// the same one.
    func test_invariant_focusedPaneAlwaysInTreeAndNoDuplicatePaneIDs_acrossMixedOperationSequence() {
        var layout = SessionPaneLayout(initialPane: UUID())
        let axes: [SplitAxis] = [.horizontal, .vertical]

        func assertInvariants(atStep step: Int) {
            XCTAssertTrue(layout.tree.contains(layout.focusedPane), "step \(step): focusedPane must always be a real pane in the tree")
            let ids = layout.paneIDs
            XCTAssertEqual(ids.count, Set(ids).count, "step \(step): paneIDs must never contain duplicates")
        }

        assertInvariants(atStep: 0)

        for i in 0..<20 {
            let doRemove = (i % 3 == 2) && layout.paneCount > 1
            if doRemove {
                // Deterministically pick a target pane index that isn't
                // always the focused pane, so this also exercises removing
                // an unfocused pane, not just the "focus must move" path.
                let ids = layout.paneIDs
                let target = ids[(i * 7) % ids.count]
                let outcome = layout.removePane(target)
                XCTAssertNotEqual(outcome, .notFound, "step \(i + 1): the target pane was taken straight from paneIDs, so it must always be found")
            } else {
                layout.splitFocused(axis: axes[i % 2], adding: UUID())
            }
            assertInvariants(atStep: i + 1)
        }
    }
}
