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
/// An open review overlay (see `OverlayCenter`) is hosted in this same
/// container and shown the same way — by hiding its siblings rather than by
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
        // A live review owns the entire pane, whatever is selected in the
        // sidebar. Checked before the selection at all, so that switching
        // sessions mid-review cannot pull the review off screen and strand
        // the agent waiting on a surface the user can no longer see.
        if let overlayView = overlays.currentView {
            mount(overlayView, in: containerView)
            // Only safe once the view is in the hierarchy — see
            // OverlayCenter.deliverCommandIfNeeded.
            overlays.deliverCommandIfNeeded()
            reveal(overlayView, in: containerView)
            return
        }

        guard let selectedID = store.selection,
              let row = store.sessions.first(where: { $0.id == selectedID }),
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
