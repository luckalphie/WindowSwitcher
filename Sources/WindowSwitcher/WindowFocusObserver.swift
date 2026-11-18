import AppKit
import ApplicationServices

// 每个应用只注册一个 AX 观察者；回调只排队读取，避免在通知中执行跨进程查询。
final class WindowFocusObserver {
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pendingReads: [pid_t: DispatchWorkItem] = [:]
    private var readGeneration: UInt64 = 0
    private let readQueue = DispatchQueue(label: "WindowSwitcher.focusReads", qos: .userInitiated, attributes: .concurrent)
    private let onFocus: (pid_t, AXUIElement) -> Void

    init(onFocus: @escaping (pid_t, AXUIElement) -> Void) {
        self.onFocus = onFocus
    }

    func start() {
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.observe(app) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.remove(app.processIdentifier) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.observe(app)
                self?.scheduleRead(app.processIdentifier)
            }
        })
    }

    func scheduleRead(_ pid: pid_t, delay: TimeInterval = 0.06) {
        pendingReads[pid]?.cancel()
        readGeneration &+= 1
        let generation = readGeneration
        let work = DispatchWorkItem { [weak self] in self?.readFocusedWindow(pid, generation: generation) }
        pendingReads[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier, observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            let owner = Unmanaged<WindowFocusObserver>.fromOpaque(context).takeUnretainedValue()
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            owner.scheduleRead(pid)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var subscribed = false
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            let result = AXObserverAddNotification(observer, element, name as CFString, context)
            subscribed = subscribed || result == .success || result == .notificationAlreadyRegistered
        }
        guard subscribed else { return }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func readFocusedWindow(_ pid: pid_t, generation: UInt64) {
        pendingReads[pid] = nil
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        readQueue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            let window = value as! AXUIElement
            DispatchQueue.main.async { [weak self] in
                guard let self, self.readGeneration == generation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.onFocus(pid, window)
            }
        }
    }

    private func remove(_ pid: pid_t) {
        pendingReads.removeValue(forKey: pid)?.cancel()
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    deinit {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for pid in Array(observers.keys) { remove(pid) }
    }
}
