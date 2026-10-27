import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices

struct SwitchableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let pid: pid_t
    let icon: NSImage
    let frame: CGRect

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

final class WindowCatalog {
    func windows() -> [SwitchableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) > 80,
                  ((bounds["Height"] as? NSNumber)?.doubleValue ?? 0) > 50 else { return nil }
            let title = (info[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = ownerPID.int32Value
            let frame = CGRect(
                x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            )
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  !isModalOrTransient(pid: pid, title: title, frame: frame) else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let name = title.isEmpty ? owner : title
            return SwitchableWindow(id: CGWindowID(number.uint32Value), title: name, appName: owner, pid: pid, icon: app?.icon ?? NSImage(named: NSImage.applicationIconName)!, frame: frame)
        }
        .sorted { a, b in
            if a.pid == frontmostPID && b.pid != frontmostPID { return true }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private func isModalOrTransient(pid: pid_t, title: String, frame: CGRect) -> Bool {
        // Window level is already filtered above. AX subroles catch sheets and dialogs
        // that are still reported at the normal level by some AppKit applications.
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var axTitle: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &axTitle)
            let candidateTitle = (axTitle as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // CG window titles are often empty for Java/Chromium apps. Match by
            // screen frame first, then use title as a fallback.
            let matchesTitle = !title.isEmpty && candidateTitle == title
            let matchesFrame = axFrame(window).map { framesMatch($0, frame) } ?? false
            if !matchesTitle && !matchesFrame { continue }
            var subrole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            let role = subrole as? String ?? ""
            if ["AXDialog", "AXSystemDialog", "AXSheet"].contains(role) { return true }
        }
        return false
    }

    private func axFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              positionValue != nil,
              sizeValue != nil else { return nil }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2 &&
        abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }
}

final class WindowActivator {
    func activate(_ window: SwitchableWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let axApp = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        var fallback: AXUIElement?
        var titleFallback: AXUIElement?
        for item in windows {
            if fallback == nil { fallback = item }
            var axTitle: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &axTitle)
            if (axTitle as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == window.title { titleFallback = item }
            if let frame = axFrame(item), framesMatch(frame, window.frame) {
                focus(item)
                return
            }
        }
        focus(titleFallback ?? fallback)
    }

    private func axFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              positionValue != nil,
              sizeValue != nil else { return nil }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2 &&
        abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    private func focus(_ window: AXUIElement?) {
        guard let window else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
    }
}

struct SwitcherView: View {
    let windows: [SwitchableWindow]
    let selected: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 4)
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                HStack(spacing: 12) {
                    Image(nsImage: window.icon).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(window.title).lineLimit(1)
                        Text(window.appName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if index == selected { Text("⌘Tab").font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(index == selected ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
        }.padding(14).frame(width: 460).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true; level = .statusBar; hasShadow = true; isOpaque = false; backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    func show(windows: [SwitchableWindow], selected: Int) {
        contentView = NSHostingView(rootView: SwitcherView(windows: windows, selected: selected))
        let size = contentView!.fittingSize; setContentSize(size)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
        orderFrontRegardless()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = WindowCatalog(); private let activator = WindowActivator(); private let panel = OverlayPanel()
    private var tap: CFMachPort?; private var windows: [SwitchableWindow] = []; private var selected = 0; private var held = false; private var sessionActive = false
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
        let flags = event.flags
        if type == .flagsChanged {
            held = flags.contains(.maskCommand)
            if held && !sessionActive {
                refresh()
                selected = 0
                sessionActive = true
            }
            if !held && sessionActive { finish(); return nil }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, flags.contains(.maskCommand), event.getIntegerValueField(.keyboardEventKeycode) == 48 else { return Unmanaged.passUnretained(event) }
        if !sessionActive { refresh(); selected = 0; sessionActive = true }
        else if panel.isVisible { selected = (selected + 1) % max(windows.count, 1) }
        if !windows.isEmpty { panel.show(windows: windows, selected: selected) }
        return nil
    }
    private func finish() { panel.orderOut(nil); if !windows.isEmpty { activator.activate(windows[selected]) }; sessionActive = false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
