import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import Darwin
enum WindowIdentity: Hashable {
    case accessibility(pid: pid_t, elementHash: CFHashCode)
    case coreGraphics(CGWindowID)
}

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
