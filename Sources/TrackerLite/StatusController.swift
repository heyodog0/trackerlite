// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

/// Owns the menu-bar status item (a timer glyph + elapsed / today total) and the
/// glass panel. The panel's window is a clear canvas kept at least as tall as
/// the SwiftUI glass (plus a shadow margin); all visible resizing is SwiftUI's.
@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let state = AppState()
    private let panel: GlassPanel
    private var cancellables: Set<AnyCancellable> = []

    private let width: CGFloat = panelWidth
    private let minHeight: CGFloat = 130
    private let maxHeight: CGFloat = 700
    private let fallbackHeight: CGFloat = 300   // before the content first measures
    private var originX: CGFloat = 0
    private var pinnedTopY: CGFloat = 0
    // Until the panel has finished opening, shrink the window immediately; after
    // that, wait for the glass to finish collapsing first (see syncWindowSize).
    private var panelSettled = false
    /// Bumped on every open/close so a finished close fade can tell it's stale.
    private var transition = 0
    /// Last badge text drawn — the 1s tick fires every second but the menu-bar
    /// label only changes each minute, so skip the redraw when it matches.
    private var lastBadge: String?
    /// ⌃⌥T starts/stops the timer from anywhere (toggle in the right-click menu).
    private var hotKey: HotKey?
    private var hotKeyEnabled = UserDefaults.standard.object(forKey: "hotKeyEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hotKeyEnabled, forKey: "hotKeyEnabled"); syncHotKey() }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = GlassPanel(content: RootView().environmentObject(state))
        super.init()
        panel.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateBadge(force: true)
        syncHotKey()

        // Enable launch-at-login once; the right-click menu lets the user turn
        // it off later without it re-enabling each launch.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "loginItemConfigured") {
            LoginItem.forceEnable()
            defaults.set(true, forKey: "loginItemConfigured")
        }

        // The tick drives the elapsed label; start/stop changes the glyph.
        state.$now
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)
        state.$data
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge(force: true) }
            .store(in: &cancellables)

        // The SwiftUI glass publishes its full height; keep the transparent window
        // at least that tall so it never clips the glass. Resizing is invisible
        // (the window's margins are clear), so all motion is the SwiftUI glass
        // animating its own height.
        state.$panelContentHeight
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncWindowSize() }
            .store(in: &cancellables)

        // Let SwiftUI (tap outside the glass) dismiss the panel.
        state.closePanel = { [weak self] in self?.close() }

        // When the color panel goes away, take key back so the glass behaves
        // normally again (next click outside dismisses it). Without this it would
        // linger un-key and un-dismissable.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                guard note.object is NSColorPanel else { return }
                Task { @MainActor in
                    guard let self, self.panel.isVisible else { return }
                    self.panel.makeKeyAndOrderFront(nil)
                }
            }

        // Scriptable toggle, for screenshotting the panel without a click:
        // Scripts/toggle-panel.swift posts this.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.heyodog0.trackerlite.togglePanel"),
            object: nil, queue: .main
        ) { [weak self] n in
            MainActor.assumeIsolated {
                // An optional tab to open on: track or stats.
                if let tab = (n.object as? String).flatMap(PanelTab.init) { self?.state.tab = tab }
                self?.togglePanel()
            }
        }
    }

    private func panelHeight() -> CGFloat {
        let h = state.panelContentHeight
        guard h > 0 else { return fallbackHeight }
        return min(max(h, minHeight), maxHeight)
    }

    // MARK: - clicks

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        isRight ? showMenu() : togglePanel()
    }

    private func togglePanel() { panel.isVisible ? close() : open() }

    private func showMenu() {
        if panel.isVisible { close() }
        let menu = NSMenu()

        // Start/stop without opening the panel — the whole point of the app is
        // that clocking in is one gesture.
        let running = state.running != nil
        let toggle = NSMenuItem(title: running ? "Stop Timer" : "Start Timer",
                                action: #selector(toggleTimer), keyEquivalent: "s")
        toggle.target = self
        menu.addItem(toggle)
        if let r = state.running {
            let label = r.note.isEmpty ? state.name(r.projectID) : r.note
            let info = NSMenuItem(title: "\(label) — \(clock(state.runningElapsed))",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())

        let today = NSMenuItem(title: "Today: \(hm(state.todaySeconds))   Week: \(hm(state.weekSeconds))",
                               action: nil, keyEquivalent: "")
        today.isEnabled = false
        menu.addItem(today)
        menu.addItem(.separator())

        let export = NSMenuItem(title: "Export CSV", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        for (title, period) in [("This Week", Period.week), ("This Month", .month)] as [(String, Period?)]
            + [("All Time", nil)] {
            let item = NSMenuItem(title: title + "…", action: #selector(exportCSV(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = period?.rawValue
            exportMenu.addItem(item)
        }
        export.submenu = exportMenu
        menu.addItem(export)
        let reveal = NSMenuItem(title: "Reveal Data File",
                                action: #selector(revealData), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let idle = NSMenuItem(title: "Stop When Idle (2 min)",
                              action: #selector(toggleAutoStop), keyEquivalent: "")
        idle.target = self
        idle.state = state.autoStopWhenIdle ? .on : .off
        menu.addItem(idle)
        let shortcut = NSMenuItem(title: "Start/Stop Shortcut (⌃⌥T)",
                                  action: #selector(toggleHotKey), keyEquivalent: "")
        shortcut.target = self
        shortcut.state = hotKeyEnabled && hotKey != nil ? .on : .off
        if hotKeyEnabled && hotKey == nil { shortcut.toolTip = "Another app is using ⌃⌥T" }
        menu.addItem(shortcut)
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TrackerLite",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        }
    }

    @objc private func toggleTimer() { state.toggle() }
    @objc private func revealData() { state.revealDataFile() }
    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func toggleAutoStop() { state.autoStopWhenIdle.toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func toggleHotKey() { hotKeyEnabled.toggle() }

    @objc private func exportCSV(_ sender: NSMenuItem) {
        let period = (sender.representedObject as? String).flatMap(Period.init(rawValue:))
        state.exportCSV(period?.range(containing: Date()),
                        label: sender.title.replacingOccurrences(of: "…", with: ""))
    }

    private func syncHotKey() {
        hotKey = hotKeyEnabled
            ? HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
                MainActor.assumeIsolated { self?.state.toggle() }
              }
            : nil
    }

    // MARK: - panel show / hide

    private func open() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        let buttonFrame = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        let h = panelHeight()
        var x = buttonFrame.midX - width / 2   // glass left edge
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 6), vis.maxX - width - 6)
        }
        originX = x - shadowMargin
        pinnedTopY = buttonFrame.minY

        setWindow(h)

        // Start transparent; the window's alpha fades the glass in (see RootView
        // for why nothing inside the panel moves).
        transition += 1
        panelSettled = false
        state.panelVisible = false
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Don't let the key window auto-focus the note field — the cursor
            // should only appear when the user clicks it.
            self.panel.makeFirstResponder(nil)
            self.syncWindowSize()
            // A plain ease on a pure fade: a spring would overshoot, and with
            // opacity there's nothing for the overshoot to express but clipping.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.openDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
            }
            self.state.panelVisible = true
            self.panelSettled = true
        }
    }

    /// Keep the transparent window tall enough to contain the SwiftUI glass, top
    /// edge pinned. Growing applies immediately (the new space is clear, so it's
    /// invisible and gives the glass room to animate into). Shrinking waits for
    /// the glass to finish collapsing, then tightens — also invisible.
    private func syncWindowSize() {
        guard panel.isVisible else { return }
        let target = panelHeight()
        let current = panel.frame.height - shadowMargin
        guard abs(target - current) > 0.5 else { return }
        if !panelSettled || target > current {
            setWindow(target)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration + 0.04) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.setWindow(self.panelHeight())
            }
        }
    }

    private func setWindow(_ h: CGFloat) {
        let h = h + shadowMargin
        panel.setFrame(NSRect(x: originX, y: pinnedTopY - h,
                              width: width + 2 * shadowMargin, height: h),
                       display: true)
    }

    private func close() {
        statusItem.button?.highlight(false)
        panel.makeFirstResponder(nil)
        state.showingNewProject = false
        state.newProjectName = ""
        state.showingColorPicker = false
        state.showingProjectList = false
        state.showingGoalEditor = false
        state.styledProjectID = nil
        state.sessionDraft = nil
        ColorPanelBridge.shared.detach()
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        panelSettled = false

        // Fade the window out; order it out when the fade completes. The token
        // drops a stale completion if the panel was reopened meanwhile.
        transition += 1
        let token = transition
        state.panelVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == token else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        // Opening the system color panel takes key away from us — that must not
        // dismiss the glass (you'd lose the picker the instant you opened it).
        // Checked on the next tick, once the new key window is settled.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { return }
            self.close()
        }
    }

    // MARK: - menu-bar glyph + label

    /// While running: a filled timer glyph, **green**, with the session's elapsed
    /// h:mm beside it — visible from across the room that the clock is on. Idle:
    /// a template glyph (macOS tints it to the bar, like the native clock) with
    /// today's total, or nothing yet tracked today.
    private func updateBadge(force: Bool = false) {
        let running = state.running != nil
        let text = running ? hmShort(state.runningElapsed)
                           : (state.todaySeconds >= 60 ? hmShort(state.todaySeconds) : "")
        let key = "\(running)|\(text)"
        guard force || key != lastBadge else { return }
        lastBadge = key
        statusItem.button?.image = Self.badgeImage(text: text, running: running)
        statusItem.button?.toolTip = running
            ? "Tracking — \(clock(state.runningElapsed))"
            : "Today: \(hm(state.todaySeconds))"
    }

    private static func badgeImage(text label: String, running: Bool) -> NSImage {
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let cfg = running
            ? base.applying(NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
            : base
        let symbol = running ? "timer.circle.fill" : "timer"
        let icon = (NSImage(systemSymbolName: symbol, accessibilityDescription: "TrackerLite")?
            .withSymbolConfiguration(cfg)) ?? NSImage()

        guard !label.isEmpty else {
            icon.isTemplate = !running
            return icon
        }

        let text = label as NSString
        let textColor: NSColor = running ? .systemGreen : .black   // black → template-tinted
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: textColor,
        ]
        let textSize = text.size(withAttributes: attrs)
        let gap: CGFloat = 3
        let iconSize = icon.size
        let h = max(iconSize.height, textSize.height)
        let w = iconSize.width + gap + textSize.width

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (h - iconSize.height) / 2,
                                 width: iconSize.width, height: iconSize.height))
            text.draw(at: NSPoint(x: iconSize.width + gap, y: (h - textSize.height) / 2),
                      withAttributes: attrs)
            return true
        }
        img.isTemplate = !running   // template ⇒ macOS colors the label to the bar
        return img
    }
}
