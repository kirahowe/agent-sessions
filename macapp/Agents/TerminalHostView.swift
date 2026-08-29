import AppKit
import GhosttyTerminal
import SwiftUI

/// A single container for every active session's TerminalView. Switching the
/// selected session only toggles visibility and focus; live views are never
/// reparented because that blanks their Metal surfaces. Workspace closing is
/// the deliberate exception: TerminalCenter removes and frees each target
/// surface while it is quiesced, and this host must not lazily request a new
/// one until the manager outcome resumes that session.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var store: AppStore
    @ObservedObject var center: TerminalCenter

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ containerView: NSView, context: Context) {
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

        if terminalView.superview !== containerView {
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: containerView.topAnchor),
                terminalView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
        }

        center.showResumeHintIfNeeded(for: selectedID)

        for subview in containerView.subviews {
            subview.isHidden = subview !== terminalView
        }

        containerView.window?.makeFirstResponder(terminalView)
        terminalView.fitToSize()
    }
}
