import AppKit
import GhosttyTerminal
import SwiftUI

/// A single container for every active session's TerminalView. Switching the
/// selected session only toggles visibility and focus; live views are never
/// reparented because that blanks their Metal surfaces. Workspace closing is
/// the deliberate exception: TerminalCenter removes and frees each target
/// surface while it is quiesced, and this host must not lazily request a new
/// one until the manager outcome resumes that session.
///
/// Open review overlays (see `OverlayCenter`) are hosted in this same
/// container and shown the same way — by hiding their siblings rather than by
/// removing them. That is what lets a review take the whole pane while the
/// session underneath keeps running and comes back untouched on exit.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var store: AppStore
    @ObservedObject var center: TerminalCenter
    @ObservedObject var overlays: OverlayCenter

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ containerView: NSView, context: Context) {
        // Every live overlay is mounted, not just the selected session's: a
        // review can be requested by a session that isn't on screen, and its
        // command cannot be delivered — the review never starts — until its
        // surface exists, which requires the view to be in the hierarchy.
        // Mounting is not revealing: which single subview is visible is
        // decided below, so a hidden session's review runs behind the scenes.
        for overlayView in overlays.allViews {
            mount(overlayView, in: containerView)
        }
        // Only safe once the views are in the hierarchy — see
        // OverlayCenter.deliverCommandsIfNeeded.
        overlays.deliverCommandsIfNeeded()

        guard let selectedID = store.selection else {
            for subview in containerView.subviews {
                subview.isHidden = true
            }
            return
        }

        // The selected session's own review owns its pane. Scoped to the
        // selection: another session's review must never take over work the
        // user is looking at — it stays mounted, hidden, and running, and
        // reselecting its session restores it exactly where it was.
        if let overlayView = overlays.view(forSession: selectedID) {
            reveal(overlayView, in: containerView)
            return
        }

        guard let row = store.sessions.first(where: { $0.id == selectedID }),
              !center.isSessionQuiesced(selectedID),
              let terminalView = center.terminalView(
                  for: selectedID,
                  workingDirectory: store.workingDirectory(for: row),
                  restoredResume: row.resume
              )
        else {
            for subview in containerView.subviews {
                subview.isHidden = true
            }
            return
        }

        mount(terminalView, in: containerView)
        center.showResumeHintIfNeeded(for: selectedID)
        reveal(terminalView, in: containerView)
    }

    /// Adds the view to the container pinned to all four edges, once. Repeat
    /// calls are no-ops: re-adding a live surface is exactly the reparenting
    /// that blanks it.
    private func mount(_ terminalView: TerminalView, in containerView: NSView) {
        guard terminalView.superview !== containerView else { return }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: containerView.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    /// Makes exactly one hosted surface visible and focused.
    private func reveal(_ terminalView: TerminalView, in containerView: NSView) {
        for subview in containerView.subviews {
            subview.isHidden = subview !== terminalView
        }
        containerView.window?.makeFirstResponder(terminalView)
        terminalView.fitToSize()
    }
}
