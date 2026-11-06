import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import Darwin
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = WindowCatalog(); private let activator = WindowActivator(); private let panel = OverlayPanel()
    private var tap: CFMachPort?; private var windows: [SwitchableWindow] = []; private var selected = 0; private var held = false; private var sessionActive = false; private var tabPressed = false; private var overlayTimer: Timer?; private var bypassingScreenSharing = false
    private var sessionOrigin: SwitchableWindow?; private var lastActivatedWindow: SwitchableWindow?; private var lastSwitchSource: SwitchableWindow?
    private let overlayDelay: TimeInterval = 0.18
    private var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        requestAccessibilityPermission()
        installEventTap()
        refresh()
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("WindowSwitcher: Accessibility permission is required for Command+Tab")
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WindowSwitcher")
            button.image?.isTemplate = true
            button.toolTip = "WindowSwitcher"
        }

        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "刷新窗口列表", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let accessibilityItem = NSMenuItem(title: "打开辅助功能设置", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        let screenRecordingItem = NSMenuItem(title: "打开屏幕录制设置", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        screenRecordingItem.target = self
        menu.addItem(screenRecordingItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 WindowSwitcher", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func refreshFromMenu() { refresh() }

    @objc private func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    @objc private func openScreenRecordingSettings() {
        openSettings(anchor: "Privacy_ScreenCapture")
    }

    private func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
    private func refresh() { windows = catalog.windows() }
    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            return delegate.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if tap == nil { NSLog("WindowSwitcher: unable to install event tap; enable Accessibility permission for WindowSwitcher.app") }
        if let tap { let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true) }
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // AX 查询偶发阻塞时，macOS 会停用事件监听；立即恢复，避免 Cmd+Tab 永久失效。
            NSLog("WindowSwitcher: event tap was disabled; re-enabling it")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = CFAbsoluteTimeGetCurrent() - startedAt
            if duration > 0.1 {
                NSLog("WindowSwitcher: hotkey event processing took %.0f ms", duration * 1_000)
            }
        }
        let flags = event.flags
        if type == .flagsChanged {
            held = flags.contains(.maskCommand)
            if held && !sessionActive && isScreenSharingFullscreen() {
                bypassingScreenSharing = true
                return Unmanaged.passUnretained(event)
            }
            if bypassingScreenSharing {
                if !held { bypassingScreenSharing = false }
                return Unmanaged.passUnretained(event)
            }
            if held && !sessionActive {
                refresh()
                sessionOrigin = catalog.frontmostWindow(in: windows)
                selected = initialSelection(reverse: flags.contains(.maskShift))
                sessionActive = true
                tabPressed = false
            }
            if !held && sessionActive {
                if panel.isVisible {
                    finish()
                    return nil
                }
                overlayTimer?.invalidate()
                overlayTimer = nil
                if tabPressed && !windows.isEmpty {
                    let target = windows[selected]
                    activateSelection(target)
                    sessionActive = false
                    tabPressed = false
                    return nil
                }
                // Command by itself is not a switch request. Keep the event
                // flowing to macOS and discard the temporary session state.
                sessionActive = false
                sessionOrigin = nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, flags.contains(.maskCommand), event.getIntegerValueField(.keyboardEventKeycode) == 48 else { return Unmanaged.passUnretained(event) }
        if bypassingScreenSharing || isScreenSharingFullscreen() {
            bypassingScreenSharing = true
            return Unmanaged.passUnretained(event)
        }
        if !sessionActive {
            refresh()
            sessionOrigin = catalog.frontmostWindow(in: windows)
            selected = initialSelection(reverse: flags.contains(.maskShift))
            sessionActive = true
        }
        if !tabPressed {
            tabPressed = true
            scheduleOverlay()
        } else if panel.isVisible {
            cycleSelection(reverse: flags.contains(.maskShift))
            showPanel()
        } else if !windows.isEmpty {
            // A repeated Tab during the delay still changes the eventual target.
            cycleSelection(reverse: flags.contains(.maskShift))
        }
        return nil
    }
    private func scheduleOverlay() {
        overlayTimer?.invalidate()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: overlayDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.overlayTimer = nil
            guard self.held, self.sessionActive, self.tabPressed else { return }
            self.showPanel()
        }
    }

    private func showPanel() {
        guard !windows.isEmpty else { return }
        panel.show(windows: windows, selected: selected) { [weak self] index in
            self?.selectFromMouse(index)
        }
    }

    private func cycleSelection(reverse: Bool) {
        guard !windows.isEmpty else { return }
        let count = windows.count
        selected = reverse ? (selected - 1 + count) % count : (selected + 1) % count
    }

    private func finish() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        panel.orderOut(nil)
        if !windows.isEmpty {
            let target = windows[selected]
            activateSelection(target)
        }
        sessionActive = false
        tabPressed = false
    }

    private func selectFromMouse(_ index: Int) {
        guard windows.indices.contains(index) else { return }
        selected = index
        overlayTimer?.invalidate()
        overlayTimer = nil
        panel.orderOut(nil)
        let target = windows[index]
        activateSelection(target)
        sessionActive = false
        tabPressed = false
    }

    private func initialSelection(reverse: Bool) -> Int {
        guard windows.count > 1 else { return 0 }
        if !reverse,
           let lastActivatedWindow,
           let lastSwitchSource,
           catalog.matchesFrontmost(lastActivatedWindow),
           let sourceIndex = catalog.index(of: lastSwitchSource, in: windows) {
            return sourceIndex
        }
        if let currentID = catalog.frontmostID,
           let currentIndex = windows.firstIndex(where: { $0.id == currentID }) {
            return reverse
                ? (currentIndex - 1 + windows.count) % windows.count
                : (currentIndex + 1) % windows.count
        }
        return reverse ? windows.count - 1 : 1
    }

    private func activateSelection(_ target: SwitchableWindow) {
        if let sessionOrigin, !catalog.matches(sessionOrigin, target) {
            lastSwitchSource = sessionOrigin
            lastActivatedWindow = target
        }
        activator.activate(target)
        catalog.markRecentlyUsed(target)
        sessionOrigin = nil
    }

    private func isScreenSharingFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.ScreenSharing" else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var candidates: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attribute as CFString, &value) == .success,
               let value {
                let window = value as! AXUIElement
                candidates.append(window)
            }
        }
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            candidates.append(contentsOf: windows)
        }

        // Prefer the explicit AX state. It remains reliable when a full-screen
        // session uses a display arrangement that does not match the window list.
        for window in candidates {
            var fullscreenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenValue) == .success,
               (fullscreenValue as? NSNumber)?.boolValue == true {
                return true
            }
        }

        guard let displayBounds = currentDisplayBounds() else { return false }
        let tolerance: CGFloat = 8
        for window in candidates {
            guard let frame = axFrame(window) else { continue }
            let matchesDisplay = abs(frame.minX - displayBounds.minX) <= tolerance &&
                abs(frame.minY - displayBounds.minY) <= tolerance &&
                abs(frame.width - displayBounds.width) <= tolerance &&
                abs(frame.height - displayBounds.height) <= tolerance
            if matchesDisplay { return true }
        }
        return false
    }

    private func currentDisplayBounds() -> CGRect? {
        let mouse = CGEvent(source: nil)?.location ?? .zero
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount) == .success else { return nil }
        for display in displays.prefix(Int(displayCount)) {
            let bounds = CGDisplayBounds(display)
            if bounds.contains(mouse) { return bounds }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    private func axFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else { return nil }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
