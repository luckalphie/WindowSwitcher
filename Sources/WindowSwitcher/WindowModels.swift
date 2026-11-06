import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import Darwin
// 窗口的稳定业务主键。AXUIElement 是系统返回的远程对象引用，不能直接用作跨刷新缓存的 key。
enum WindowIdentity: Hashable {
    case accessibility(pid: pid_t, elementHash: CFHashCode)
    case coreGraphics(CGWindowID)
}

// 业务层窗口 DTO：Catalog 负责组装，UI 负责展示，Activator 负责按此对象激活窗口。
struct SwitchableWindow: Identifiable, Hashable {
    let id: WindowIdentity
    let appName: String
    let title: String
    let pid: pid_t
    let icon: NSImage
    let frame: CGRect
    let accessibilityElement: AXUIElement?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
