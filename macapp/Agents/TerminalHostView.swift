import AppKit
import GhosttyTerminal
import SwiftUI

/// A single, permanently-mounted container for every live session's
/// `TerminalView`. Reparenting or recreating a live `TerminalView` blanks
/// its Metal surface, so `makeNSView` builds the container exactly once for
/// the app's whole lifetime, and every session's terminal becomes a
/// permanent subview added at most once. Switching the selected session
/// only toggles `.isHidden` and moves first responder — it never
/// adds/removes/reparents views. Views are only ever removed when their
/// session is actually closed (via `TerminalCenter`, which happens
/// elsewhere).
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var store: AppStore
    let center: TerminalCenter

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ containerView: NSView, context: Context) {
        guard let selectedID = store.selection,
              let row = store.sessions.first(where: { $0.id == selectedID })
        else {
            for subview in containerView.subviews {
                subview.isHidden = true
            }
            return
        }

        let terminalView = center.terminalView(
            for: selectedID,
            workingDirectory: store.workingDirectory(for: row),
            restoredOmpResume: row.ompResume
        )

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
