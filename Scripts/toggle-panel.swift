// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

// Opens/closes the TrackerLite panel without clicking the menu-bar item — for
// screenshots (launch with --demo for sample data).
// Usage: swift Scripts/toggle-panel.swift [track|stats]
import Foundation

let tab = CommandLine.arguments.dropFirst().first
DistributedNotificationCenter.default().postNotificationName(
    .init("com.heyodog0.trackerlite.togglePanel"), object: tab,
    userInfo: nil, deliverImmediately: true)
