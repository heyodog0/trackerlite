// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI
import AppKit

// MARK: layout — shared so the measured panel height and the views agree.

let panelWidth: CGFloat = 300
let panelCornerRadius: CGFloat = 26
let panelShape = RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
/// Padding inside the glass, on every side.
let panelPadding: CGFloat = 12
/// Clear margin around the glass (sides + bottom) inside the window, so the
/// SwiftUI shadow can fade out instead of being cut off at the window edge.
let shadowMargin: CGFloat = 44

/// The selected-segment fill shared by the tab switch, period picker and the
/// active ActionButton.
func pillFill(_ tint: Color = .blue) -> LinearGradient {
    LinearGradient(colors: [tint, tint.opacity(0.82)], startPoint: .top, endPoint: .bottom)
}

/// Shared motion, so every change moves with the same feel.
enum Motion {
    /// Anything that resizes the panel: tab switches, the project list, color
    /// row and new-project field opening or closing.
    static let duration: Double = 0.34
    static let screen = Animation.spring(duration: duration, bounce: 0.08)
    /// Small in-place changes: pills, button tints, the copy confirmation.
    static let quick = Animation.snappy(duration: 0.22)
    /// Outgoing screen fades fast so it never overlaps the incoming one.
    static let fadeOut = Animation.easeOut(duration: 0.1)
    /// Panel open/close: the window's alpha alone (see RootView for why nothing
    /// inside the panel moves).
    static let openDuration: Double = 0.18
    static let closeDuration: Double = 0.14
}

/// Real AppKit Liquid Glass (NSGlassEffectView) exposed to SwiftUI so SwiftUI can
/// size and animate it. The window itself is transparent; this is what you see.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = panelCornerRadius
    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.cornerRadius = cornerRadius
        return v
    }
    func updateNSView(_ v: NSGlassEffectView, context: Context) {
        v.cornerRadius = cornerRadius
    }
}

/// Outer SwiftUI content. The window is a transparent canvas; this draws the
/// glass panel (hugging its content, top-pinned) over a clear backdrop. Tapping
/// the backdrop dismisses, like clicking outside a popover.
struct RootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.closePanel?() }

            MenuContent()
                .geometryGroup()
                // Opening fades the whole window (StatusController) — deliberately
                // no scale or offset on open.
                //
                // The panel contains AppKit-backed controls (the note TextField is
                // an NSTextField; SwiftUI's Menu and ColorPicker were an NSPopUpButton
                // and NSColorWell before they were replaced). Embedded AppKit views
                // don't participate in SwiftUI's geometry group or its animation
                // transactions, so any animated *geometry* change re-frames them a
                // frame behind the surrounding content — that's the jitter, and it
                // hits every such control. A pure fade changes no geometry at all,
                // so nothing can lag. (The Control-Center-style scale-up this
                // replaces isn't worth a visibly shaky panel.) Fading the window
                // rather than this view also fades the glass's backdrop blur
                // cleanly.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .tint(.blue)
    }
}

/// Full-width action button; tints when active. Plain control on the glass
/// (not itself glass — glass-on-glass recurses).
struct ActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .blue
    var active: Bool = false
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : .primary)
        .background {
            if active {
                shape.fill(pillFill(tint))
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(active ? 0.30 : 0.12), lineWidth: 0.8))
        .animation(Motion.quick, value: active)
    }
}

/// Small uppercase section label, matching RemindLite's list headers.
struct SectionLabel: View {
    let text: String
    var accent: Color = .secondary
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}
