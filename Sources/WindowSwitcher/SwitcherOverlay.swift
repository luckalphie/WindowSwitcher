import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import Darwin
struct SwitcherView: View {
    let windows: [SwitchableWindow]
    let selected: Int
    let maximumHeight: CGFloat
    let onSelect: (Int) -> Void

    private var listHeight: CGFloat {
        min(maximumHeight - 54, max(44, CGFloat(windows.count) * 50))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
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
                }
            }
            .frame(height: listHeight)
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
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let maximumHeight = max(160, (screen?.visibleFrame.height ?? 0) - 80)
        contentView = NSHostingView(rootView: SwitcherView(windows: windows, selected: selected, maximumHeight: maximumHeight, onSelect: onSelect))
        let size = contentView!.fittingSize; setContentSize(size)
        let visibleFrame = screen?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2))
        orderFrontRegardless()
    }
}
