import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import Darwin

struct SwitchableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let title: String
    let pid: pid_t
    let icon: NSImage
    let frame: CGRect

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

final class WindowCatalog {
    private struct AccessibilityWindow {
        let title: String
        let subrole: String
        let isModal: Bool
        let frame: CGRect
    }

    private var recentIDs: [CGWindowID] = []
    private var trackingTimer: Timer?

    func startTracking() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.recordFrontmostWindow()
        }
        recordFrontmostWindow()
    }

    func windows() -> [SwitchableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let displayBounds = currentDisplayBounds()
        let stageManagerPIDs = stageManagerApplicationPIDs(in: list)
        // Capture a focus change that happened just before Command+Tab.
        recordFrontmostWindow(in: list)

        var current = list.compactMap { info -> SwitchableWindow? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
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
            if let displayBounds, !frame.intersects(displayBounds) { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let appName = app?.localizedName ?? (info[kCGWindowOwnerName as String] as? String ?? "")
            if stageManagerPIDs.contains(pid) && isStageManagerThumbnail(frame: frame) { return nil }
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  !isModalOrTransient(pid: pid, title: title, frame: frame) else { return nil }
            let axWindow = title.isEmpty ? accessibilityWindow(pid: pid, frame: frame) : nil
            var displayTitle = title.isEmpty ? axWindow?.title : title
            if displayTitle == nil || displayTitle?.isEmpty == true {
                let isOrdinaryWindow = axWindow?.subrole == "AXStandardWindow" && axWindow?.isModal == false
                let cannotInspectWindows = !AXIsProcessTrusted() && app?.activationPolicy == .regular
                guard isOrdinaryWindow || cannotInspectWindows else { return nil }
                displayTitle = app?.localizedName ?? info[kCGWindowOwnerName as String] as? String
            }
            guard let displayTitle, !displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // Stage Manager can expose the same window once through CGWindowList
            // and again through Accessibility after it is restored. Use the
            // same identity in both paths so MRU ordering does not split it.
            let windowID = stageManagerPIDs.contains(pid)
                ? syntheticWindowID(pid: pid, title: displayTitle, frame: frame)
                : CGWindowID(number.uint32Value)
            return SwitchableWindow(id: windowID, appName: appName, title: displayTitle, pid: pid, icon: applicationIcon(for: pid, app: app), frame: frame)
        }

        if !stageManagerPIDs.isEmpty {
            var knownWindows = Set(current.map { windowKey(pid: $0.pid, frame: $0.frame) })
            for pid in stageManagerPIDs {
                let app = NSRunningApplication(processIdentifier: pid)
                for axWindow in accessibilityWindows(pid: pid) {
                    guard axWindow.subrole == "AXStandardWindow",
                          !axWindow.isModal,
                          !axWindow.frame.isEmpty,
                          axWindow.frame.width > 80,
                          axWindow.frame.height > 50,
                          displayBounds == nil || axWindow.frame.intersects(displayBounds!) else { continue }
                    let appName = app?.localizedName ?? ""
                    let title = axWindow.title.isEmpty ? appName : axWindow.title
                    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let key = windowKey(pid: pid, frame: axWindow.frame)
                    guard knownWindows.insert(key).inserted else { continue }
                    current.append(SwitchableWindow(
                        id: syntheticWindowID(pid: pid, title: title, frame: axWindow.frame),
                        appName: appName,
                        title: title,
                        pid: pid,
                        icon: applicationIcon(for: pid, app: app),
                        frame: axWindow.frame
                    ))
                }
            }
        }

        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        recentIDs.removeAll { currentByID[$0] == nil }
        let currentOrder = current.map(\.id)
        let unseen = currentOrder.filter { !recentIDs.contains($0) }
        recentIDs.append(contentsOf: unseen)
        return recentIDs.compactMap { currentByID[$0] }
    }

    func markRecentlyUsed(_ window: SwitchableWindow) {
        markRecent(window.id)
    }

    private func stageManagerApplicationPIDs(in list: [[String: Any]]) -> Set<pid_t> {
        let hasWindowManager = list.contains { ($0[kCGWindowOwnerName as String] as? String) == "WindowManager" }
        guard hasWindowManager else { return [] }
        return Set(list.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName != "WindowManager",
                  ownerPID.int32Value != ProcessInfo.processInfo.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            return isStageManagerThumbnail(frame: CGRect(x: 0, y: 0, width: width, height: height)) ? ownerPID.int32Value : nil
        })
    }

    private func isStageManagerThumbnail(frame: CGRect) -> Bool {
        frame.width <= 400 && frame.height <= 400
    }

    private func windowKey(pid: pid_t, frame: CGRect) -> String {
        "\(pid):\(Int(frame.minX.rounded())):\(Int(frame.minY.rounded())):\(Int(frame.width.rounded())):\(Int(frame.height.rounded()))"
    }

    private func syntheticWindowID(pid: pid_t, title: String, frame: CGRect) -> CGWindowID {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(title)
        hasher.combine(frame.minX)
        hasher.combine(frame.minY)
        hasher.combine(frame.width)
        hasher.combine(frame.height)
        return UInt32(truncatingIfNeeded: hasher.finalize())
    }

    private func recordFrontmostWindow() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        recordFrontmostWindow(in: list)
    }

    private func recordFrontmostWindow(in list: [[String: Any]]) {
        let displayBounds = currentDisplayBounds()
        let stageManagerPIDs = stageManagerApplicationPIDs(in: list)

        // CGWindowList ordering changes while Stage Manager moves an app group
        // between the active area and the thumbnail rail. Accessibility's
        // focused window is the actual frontmost window during that transition.
        if let focused = frontmostAccessibilityWindow(),
           focused.frame.width > 80,
           focused.frame.height > 50,
           displayBounds == nil || focused.frame.intersects(displayBounds!) {
            let app = NSRunningApplication(processIdentifier: focused.pid)
            let appName = app?.localizedName ?? ""
            let resolvedTitle = focused.title.isEmpty ? appName : focused.title
            if stageManagerPIDs.contains(focused.pid) {
                markRecent(syntheticWindowID(pid: focused.pid, title: resolvedTitle, frame: focused.frame))
                return
            }

            if let number = list.compactMap({ info -> CGWindowID? in
                guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                      ownerPID.int32Value == focused.pid,
                      let layer = info[kCGWindowLayer as String] as? NSNumber,
                      layer.intValue == 0,
                      let number = info[kCGWindowNumber as String] as? NSNumber,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
                let frame = CGRect(
                    x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                    y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                    width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                    height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                )
                return framesMatch(frame, focused.frame) ? CGWindowID(number.uint32Value) : nil
            }).first {
                markRecent(number)
                return
            }
        }

        guard let id = list.compactMap({ info -> CGWindowID? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  (info[kCGWindowOwnerName as String] as? String) != "WindowManager",
                  layer.intValue == 0,
                  ownerPID.int32Value != ProcessInfo.processInfo.processIdentifier,
                  ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) > 80,
                  ((bounds["Height"] as? NSNumber)?.doubleValue ?? 0) > 50 else { return nil }
            let frame = CGRect(
                x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            )
            if let displayBounds, !frame.intersects(displayBounds) { return nil }
            let pid = ownerPID.int32Value
            if stageManagerPIDs.contains(pid) && isStageManagerThumbnail(frame: frame) { return nil }

            let title = (info[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let app = NSRunningApplication(processIdentifier: pid)
            let appName = app?.localizedName ?? (info[kCGWindowOwnerName as String] as? String ?? "")
            let resolvedTitle = title.isEmpty
                ? (accessibilityWindow(pid: pid, frame: frame)?.title ?? appName)
                : title
            return stageManagerPIDs.contains(pid)
                ? syntheticWindowID(pid: pid, title: resolvedTitle, frame: frame)
                : CGWindowID(number.uint32Value)
        }).first else { return }
        markRecent(id)
    }

    private func markRecent(_ id: CGWindowID) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
    }

    private func frontmostAccessibilityWindow() -> (pid: pid_t, title: String, frame: CGRect)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &value) == .success,
                  value != nil else { continue }
            let window = value as! AXUIElement
            guard let frame = axFrame(window) else { continue }
            var titleValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            return (
                app.processIdentifier,
                (titleValue as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                frame
            )
        }
        return nil
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
            var modalValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            _ = AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modalValue)
            let role = subrole as? String ?? ""
            let isModal = (modalValue as? NSNumber)?.boolValue == true
            let isUntitledTransient = role == "AXUnknown" && candidateTitle.isEmpty
            // IntelliJ exposes its modal windows as AXDialog while leaving
            // AXModal false. Match this specific AX window by frame first, so
            // excluding it cannot hide the app's other ordinary windows.
            // Chromium/Edge exposes address-bar suggestion popups as untitled
            // AXUnknown windows; those are transient UI, not switchable windows.
            if isModal || isUntitledTransient || ["AXDialog", "AXSystemDialog", "AXSheet"].contains(role) { return true }
        }
        return false
    }

    private func accessibilityWindows(pid: pid_t) -> [AccessibilityWindow] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            guard let frame = axFrame(window) else { return nil }
            var titleValue: CFTypeRef?
            var subroleValue: CFTypeRef?
            var modalValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
            _ = AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modalValue)
            let title = (titleValue as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return AccessibilityWindow(
                title: title,
                subrole: subroleValue as? String ?? "",
                isModal: (modalValue as? NSNumber)?.boolValue == true,
                frame: frame
            )
        }
    }

    private func accessibilityWindow(pid: pid_t, frame: CGRect) -> (title: String, subrole: String, isModal: Bool)? {
        guard let window = accessibilityWindows(pid: pid).first(where: { framesMatch($0.frame, frame) }) else { return nil }
        return (window.title, window.subrole, window.isModal)
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

    private func applicationIcon(for pid: pid_t, app: NSRunningApplication?) -> NSImage {
        if let icon = app?.icon { return icon }
        if let bundleURL = app?.bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        if let bundleIdentifier = app?.bundleIdentifier,
           let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        if let executablePath = processPath(pid) {
            var url = URL(fileURLWithPath: executablePath)
            var appURLs: [URL] = []
            while url.path != "/" {
                if url.pathExtension == "app" { appURLs.append(url) }
                url.deleteLastPathComponent()
            }
            if let appURL = appURLs.last {
                return NSWorkspace.shared.icon(forFile: appURL.path)
            }
        }
        return NSImage(named: NSImage.applicationIconName)!
    }

    private func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
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
    let onSelect: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 4)
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                Button(action: { onSelect(index) }) {
                    HStack(spacing: 12) {
                        Image(nsImage: window.icon).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(window.title).lineLimit(1)
                        }
                        Spacer()
                        if index == selected { Text("⌘Tab").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(windows: [SwitchableWindow], selected: Int, onSelect: @escaping (Int) -> Void) {
        contentView = NSHostingView(rootView: SwitcherView(windows: windows, selected: selected, onSelect: onSelect))
        let size = contentView!.fittingSize; setContentSize(size)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
        orderFrontRegardless()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = WindowCatalog(); private let activator = WindowActivator(); private let panel = OverlayPanel()
    private var tap: CFMachPort?; private var windows: [SwitchableWindow] = []; private var selected = 0; private var held = false; private var sessionActive = false; private var tabPressed = false; private var overlayTimer: Timer?; private var bypassingScreenSharing = false
    private let overlayDelay: TimeInterval = 0.18
    private var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        requestAccessibilityPermission()
        catalog.startTracking()
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
                    activator.activate(target)
                    catalog.markRecentlyUsed(target)
                    sessionActive = false
                    tabPressed = false
                    return nil
                }
                // Command by itself is not a switch request. Keep the event
                // flowing to macOS and discard the temporary session state.
                sessionActive = false
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
            activator.activate(target)
            catalog.markRecentlyUsed(target)
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
        activator.activate(target)
        catalog.markRecentlyUsed(target)
        sessionActive = false
        tabPressed = false
    }

    private func initialSelection(reverse: Bool) -> Int {
        guard windows.count > 1 else { return 0 }
        return reverse ? windows.count - 1 : 1
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
