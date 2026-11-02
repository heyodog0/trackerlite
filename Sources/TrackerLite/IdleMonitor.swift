// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import CoreGraphics
import Foundation

/// How long the mouse and keyboard have been quiet, system-wide.
///
/// `CGEventSource.secondsSinceLastEventType` is a passive read of an existing
/// counter — not an event tap and not event monitoring — so it needs no
/// Accessibility or Input Monitoring grant. TrackerLite still prompts for
/// nothing, and never sees *what* you typed, only that something happened.
enum IdleMonitor {
    /// `kCGAnyInputEventType` — any input at all, key or pointer.
    private static let anyInput = CGEventType(rawValue: ~0)

    static var idleSeconds: TimeInterval {
        guard let anyInput else { return 0 }
        // .combinedSessionState rather than .hidSystemState: it counts posted
        // events too, so a KVM, a tablet driver, or a screen-sharing session
        // reads as the presence it is instead of an empty chair.
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                       eventType: anyInput)
    }
}
