import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import Darwin
final class WindowCatalog {
    private struct AccessibilityWindow {
        let element: AXUIElement
        let title: String
        let subrole: String
        let isModal: Bool
        let frame: CGRect
    }

    private struct FrontmostWindow {
        let element: AXUIElement
        let pid: pid_t
        let frame: CGRect
    }

    private var recentIDs: [WindowIdentity] = []
    private var lastSeen: [WindowIdentity: Date] = [:]
    private let historyRetention: TimeInterval = 30
    // 台前调度在窗口切换后会短暂回报上一个焦点窗口；该时间内不能让它覆盖 MRU 顺序。
    private let activationSettlingInterval: TimeInterval = 2
    private(set) var frontmostID: WindowIdentity?
    private var pendingActivation: (id: WindowIdentity, pid: pid_t, deadline: Date)?

    func windows() -> [SwitchableWindow] {
        // 台前调度会从 CG 的 on-screen 列表移除非活动组，不能据此限定候选应用。
        // 统一从 AX 普通窗口生成列表，保证台前调度开关不影响窗口数量与顺序。
        var current = switchableWindows(displayBounds: currentDisplayBounds())

        var currentByID: [WindowIdentity: SwitchableWindow] = [:]
        current = current.filter { window in
            guard currentByID[window.id] == nil else { return false }
            currentByID[window.id] = window
            return true
        }
        if let focused = frontmostAccessibilityWindow(),
           let focusedWindow = matchingWindow(in: current, pid: focused.pid, element: focused.element, frame: focused.frame) {
            let focusedID = focusedWindow.id
            if let pending = pendingActivation, Date() < pending.deadline, focusedID != pending.id,
               focused.pid != pending.pid {
                // 切到另一应用后，台前调度可能短暂回报来源应用的旧焦点。
            } else {
                pendingActivation = nil
                markRecent(focusedID)
            }
        }
        let now = Date()
        for id in currentByID.keys { lastSeen[id] = now }
        // Stage Manager can remove a window from both APIs briefly while it
        // moves between the active area and the thumbnail rail. Keep its MRU
        // position for a short grace period, but do not return it unless it is
        // present in the current filtered window list.
        recentIDs.removeAll { id in
            guard currentByID[id] == nil else { return false }
            guard let seen = lastSeen[id] else { return true }
            return now.timeIntervalSince(seen) > historyRetention
        }
        let currentOrder = current.map(\.id)
        let unseen = currentOrder.filter { !recentIDs.contains($0) }
        recentIDs.append(contentsOf: unseen)
        return recentIDs.compactMap { currentByID[$0] }
    }

    func markRecentlyUsed(_ window: SwitchableWindow) {
        markRecent(window.id)
        pendingActivation = (window.id, window.pid, Date().addingTimeInterval(activationSettlingInterval))
    }

    func frontmostWindow(in windows: [SwitchableWindow]) -> SwitchableWindow? {
        guard let focused = frontmostAccessibilityWindow() else { return nil }
        return matchingWindow(in: windows, pid: focused.pid, element: focused.element, frame: focused.frame)
    }

    func matchesFrontmost(_ window: SwitchableWindow) -> Bool {
        guard let focused = frontmostAccessibilityWindow(), focused.pid == window.pid else { return false }
        return accessibilityElementsMatch(window.accessibilityElement, focused.element) || framesMatch(window.frame, focused.frame)
    }

    func index(of reference: SwitchableWindow, in windows: [SwitchableWindow]) -> Int? {
        windows.firstIndex { candidate in
            candidate.pid == reference.pid &&
            (accessibilityElementsMatch(candidate.accessibilityElement, reference.accessibilityElement) ||
                candidate.id == reference.id ||
                (candidate.title == reference.title && framesMatch(candidate.frame, reference.frame)))
        }
    }

    func matches(_ lhs: SwitchableWindow, _ rhs: SwitchableWindow) -> Bool {
        lhs.pid == rhs.pid &&
            (accessibilityElementsMatch(lhs.accessibilityElement, rhs.accessibilityElement) || lhs.id == rhs.id)
    }

    private func switchableWindows(displayBounds: CGRect?) -> [SwitchableWindow] {
        NSWorkspace.shared.runningApplications.flatMap { app -> [SwitchableWindow] in
            let pid = app.processIdentifier
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  app.activationPolicy == .regular,
                  !app.isTerminated else { return [] }
            let appName = app.localizedName ?? ""
            return accessibilityWindows(pid: pid).compactMap { axWindow in
                guard axWindow.subrole == "AXStandardWindow",
                      !axWindow.isModal,
                      !axWindow.frame.isEmpty,
                      axWindow.frame.width > 80,
                      axWindow.frame.height > 50,
                      displayBounds == nil || displayBounds!.contains(CGPoint(x: axWindow.frame.midX, y: axWindow.frame.midY)) else { return nil }
                let title = axWindow.title.isEmpty ? appName : axWindow.title
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return SwitchableWindow(
                    id: accessibilityIdentity(pid: pid, window: axWindow),
                    appName: appName,
                    title: title,
                    pid: pid,
                    icon: applicationIcon(for: pid, app: app),
                    frame: axWindow.frame,
                    accessibilityElement: axWindow.element
                )
            }
        }
    }

    private func accessibilityIdentity(pid: pid_t, window: AccessibilityWindow) -> WindowIdentity {
        // CFHash 与 CFEqual 一致，既能跨 AX 包装对象保持稳定，也能区分同应用中几何位置相同的窗口。
        return .accessibility(pid: pid, elementHash: CFHash(window.element))
    }

    private func accessibilityElementsMatch(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    private func matchingWindow(in windows: [SwitchableWindow], pid: pid_t, element: AXUIElement, frame: CGRect) -> SwitchableWindow? {
        windows.first { $0.pid == pid && accessibilityElementsMatch($0.accessibilityElement, element) }
            ?? windows.first { $0.pid == pid && framesMatch($0.frame, frame) }
    }

    private func markRecent(_ id: WindowIdentity) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        lastSeen[id] = Date()
        frontmostID = id
    }

    private func frontmostAccessibilityWindow() -> FrontmostWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &value) == .success,
                  value != nil else { continue }
            let element = value as! AXUIElement
            guard let frame = axFrame(element) else { continue }
            return FrontmostWindow(element: element, pid: app.processIdentifier, frame: frame)
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

    private func isModalOrTransient(pid: pid_t, frame: CGRect) -> Bool {
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

            let matchesFrame = axFrame(window).map { framesMatch($0, frame) } ?? false
            if !matchesFrame { continue }
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
                element: window,
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
