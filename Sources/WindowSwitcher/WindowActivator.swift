import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import Darwin
// 相当于窗口命令服务：先把所属应用置前，再通过 AX 将具体窗口设为主窗口和焦点窗口。
final class WindowActivator {
    func activate(_ window: SwitchableWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Stay inside the current app when switching its windows. Re-activating
        // the app makes Stage Manager reconsider the whole app group and can
        // briefly raise the wrong window.
        if frontmostPID != window.pid {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        if let element = window.accessibilityElement {
            // 正常路径直接使用 Catalog 已保存的 AX 对象，避免按 frame 二次查找误命中同尺寸窗口。
            focus(element)
            return
        }
        let axApp = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for item in windows {
            if let frame = axFrame(item), framesMatch(frame, window.frame) {
                focus(item)
                return
            }
        }
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
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
    }
}
