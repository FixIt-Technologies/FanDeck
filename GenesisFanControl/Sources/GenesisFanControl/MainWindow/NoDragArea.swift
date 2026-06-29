//
//  NoDragArea.swift
//  GenesisFanControl
//
//  Tiny NSViewRepresentable that hosts SwiftUI content but tells AppKit
//  "don't treat my pixels as a window-drag handle". Required for
//  interactive controls that sit inside the hidden-title-bar region of
//  a `.windowStyle(.hiddenTitleBar)` window — there, the default drag
//  behavior of the title-bar background intercepts clicks before any
//  SwiftUI Button can see them.
//

import SwiftUI
import AppKit

struct NoDragArea<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSView {
        let container = NoDragHostView()
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let hosting = nsView.subviews.first as? NSHostingView<Content> {
            hosting.rootView = content()
        }
    }
}

private final class NoDragHostView: NSView {
    /// AppKit asks each NSView at the click point whether it permits the
    /// window-drag gesture. Returning false here makes the title-bar
    /// background ignore our subtree, so the SwiftUI Button inside
    /// receives the click normally.
    override var mouseDownCanMoveWindow: Bool { false }
}
