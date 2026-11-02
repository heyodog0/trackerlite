// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import AppKit
import SwiftUI

/// Opens the system color panel and streams picks back.
///
/// Deliberately *not* SwiftUI's `ColorPicker`: that embeds an `NSColorWell` — a
/// real AppKit view — inside the hosting view, and embedded AppKit views don't
/// participate in SwiftUI's geometry group, so their frames land a frame behind
/// the SwiftUI content whenever the panel scales or animates its height. That's
/// the jitter. `NSColorPanel` is its own window, so nothing rides along inside
/// our animating hierarchy.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()

    private var onChange: ((Color) -> Void)?

    func show(initial: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true          // stream while dragging
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFrontRegardless()
    }

    /// Stop feeding a stale callback once the picker row is gone.
    func detach() {
        onChange = nil
        guard NSColorPanel.sharedColorPanelExists else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }
}
