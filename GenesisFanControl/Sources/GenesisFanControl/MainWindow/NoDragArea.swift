//
//  NoDragArea.swift
//  GenesisFanControl
//
//  SwiftUI <-> AppKit shim for "this view sits inside the hidden-title-bar
//  drag region, but its clicks should NOT begin a window drag."
//
//  Problem (root cause of the gear-button-no-op bug, diagnosed 2026-06-30):
//   • Window uses .windowStyle(.hiddenTitleBar). macOS still reserves the
//     top ~28 pt as a title-bar drag region.
//   • SwiftUI hosts the entire scene inside one NSHostingView. AppKit asks
//     that NSHostingView for `mouseDownCanMoveWindow` at each click in the
//     title-bar strip; the default answer is `true` for "background"
//     pixels, INCLUDING the pixels under a SwiftUI Button with .plain
//     style (it's not an NSButton, AppKit can't tell it's clickable).
//   • Result: clicks on the gear (centre y ≈ 14) become window-drag
//     gestures and never reach the SwiftUI Button's action. All prior
//     "fix the action dispatch" attempts (SettingsLink, openSettings,
//     NSApp.sendAction selector chain, ZStack reorder + allowsHitTesting)
//     could not have worked — the click never arrived.
//
//  Fix (canonical pattern, see ghostty-org/ghostty and manaflow-ai/cmux):
//   Subclass NSHostingView and force mouseDownCanMoveWindow = false. Wrap
//   any interactive control that lives inside the title-bar strip.
//
//  Crash-avoidance note: a previous NoDragArea (commit 245e849, deleted
//  in ba6fe96) used a bare NSView container + NSHostingView child with
//  manual NSLayoutConstraints. That stacked autolayout on top of
//  NSHostingView's own SizeConstraints, which caused
//  NSHostingView.SizeConstraints.update(from:) to throw at the next
//  display cycle → demangling_terminate → abort(). The fix is to make
//  the no-drag view itself an NSHostingView subclass; NSViewRepresentable
//  then handles sizing and we never write a constraint.
//

import SwiftUI
import AppKit

struct NoDragArea<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NoDragHostingView(rootView: content())
        // Let SwiftUI's intrinsic sizing flow up to the embedding view.
        // Do NOT touch translatesAutoresizingMaskIntoConstraints here.
        return view
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content()
    }

    private final class NoDragHostingView<C: View>: NSHostingView<C> {
        /// AppKit asks each NSView at the click point whether it permits
        /// the window-drag gesture. Returning false makes the title-bar
        /// background ignore our subtree, so the SwiftUI Button inside
        /// receives clicks normally.
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
