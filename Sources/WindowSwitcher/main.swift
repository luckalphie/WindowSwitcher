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
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  !isModalOrTransient(pid: pid, title: title) else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let name = title.isEmpty ? owner : title
            return SwitchableWindow(id: CGWindowID(number.uint32Value), title: name, appName: owner, pid: pid, icon: app?.icon ?? NSImage(named: NSImage.applicationIconName)!)
        }
        .sorted { a, b in
            if a.pid == frontmostPID && b.pid != frontmostPID { return true }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private func isModalOrTransient(pid: pid_t, title: String) -> Bool {
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

            // AX reports all windows for an application. Only apply the modal
            // filter to the matching CG window, so one Edge dialog cannot hide
            // every other Edge window.
            if title.isEmpty || candidateTitle != title { continue }
            var subrole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            let role = subrole as? String ?? ""
            if ["AXDialog", "AXSystemDialog", "AXSheet"].contains(role) { return true }
        }
        return false
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
        for item in windows {
            if fallback == nil { fallback = item }
            var axTitle: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &axTitle)
            if (axTitle as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) != window.title { continue }
            AXUIElementSetAttributeValue(item, kAXMainAttribute as CFString, true as CFTypeRef)
            AXUIElementSetAttributeValue(item, kAXFocusedAttribute as CFString, true as CFTypeRef)
            return
        }
        if let fallback {
            AXUIElementSetAttributeValue(fallback, kAXMainAttribute as CFString, true as CFTypeRef)
            AXUIElementSetAttributeValue(fallback, kAXFocusedAttribute as CFString, true as CFTypeRef)
        }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEventTap()
        refresh()
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
