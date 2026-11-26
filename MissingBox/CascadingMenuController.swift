//
//  CascadingMenuController.swift
//  MissingBox
//

import AppKit
import Observation
import SwiftUI

/// 级联子菜单的路由标识
enum MenuRoute: Hashable {
    case ipv6
    case proxyGroups
    case proxyGroup(String)
    case profiles
    case autoUpdate(String)
    case core
    case settings
}

/// 桥接 SwiftUI App 的 OpenWindowAction，使托管在自定义 NSPanel 中的视图也能打开声明在 MissingBoxApp.body 中的窗口
final class WindowOpener {
    private var openWindow: OpenWindowAction?

    func bind(_ action: OpenWindowAction) {
        openWindow = action
    }

    func open(id: String) {
        openWindow?(id: id)
        NSApplication.shared.activate()
    }

    func open<Value: Codable & Hashable>(id: String, value: Value) {
        openWindow?(id: id, value: value)
        NSApplication.shared.activate()
    }
}

/// 各级悬浮菜单视图共享的交互协调器：记录每一级当前展开的子菜单路由以维持父级高亮，并转发悬浮/关闭指令
@Observable
final class MenuCoordinator {
    /// level -> 当前由该级展开的下级路由（用于保持父级触发行高亮）
    private(set) var activeRoutes: [Int: MenuRoute] = [:]

    @ObservationIgnored weak var controller: CascadingMenuController?

    func isRouteActive(_ route: MenuRoute, atParentLevel level: Int) -> Bool {
        activeRoutes[level] == route
    }

    fileprivate func syncActiveRoutes(from entries: [(level: Int, route: MenuRoute?)]) {
        var updated: [Int: MenuRoute] = [:]
        for entry in entries where entry.level > 0 {
            if let route = entry.route {
                updated[entry.level - 1] = route
            }
        }
        if updated != activeRoutes {
            activeRoutes = updated
        }
    }

    /// 鼠标悬浮到可展开子菜单的行上（带短延迟防扫过闪烁）
    func hoverSubmenu(_ route: MenuRoute, fromLevel level: Int, rowScreenRect: NSRect) {
        controller?.scheduleOpenSubmenu(route, fromLevel: level, rowScreenRect: rowScreenRect, immediate: false)
    }

    /// 点击可展开子菜单的行时立即展开
    func openSubmenu(_ route: MenuRoute, fromLevel level: Int, rowScreenRect: NSRect) {
        controller?.scheduleOpenSubmenu(route, fromLevel: level, rowScreenRect: rowScreenRect, immediate: true)
    }

    /// 鼠标悬浮到普通行上：延迟关闭更深层子菜单，给斜向滑入子菜单留出过渡时间
    func hoverPlainRow(atLevel level: Int) {
        controller?.scheduleCloseDeeper(than: level)
    }

    /// 鼠标进入某级面板内部：取消正在等待关闭该级的计时器
    func hoverPanel(atLevel level: Int) {
        controller?.cancelCloseIfEntering(level: level)
    }

    /// 仅关闭指定层级（及其更深子级），父级菜单保持打开
    func closeLevel(_ level: Int) {
        controller?.closeFrom(level: level)
    }

    /// 关闭整棵菜单
    func closeAll() {
        controller?.closeAll()
    }

    /// 打开独立应用窗口并收起整棵菜单
    func openAppWindow(id: String) {
        controller?.openAppWindow(id: id)
    }

    func openAppWindow<Value: Codable & Hashable>(id: String, value: Value) {
        controller?.openAppWindow(id: id, value: value)
    }
}

/// 管理状态栏图标与多级无边框毛玻璃 NSPanel：
/// - 每级面板高度严格贴合 SwiftUI 视图固有尺寸，绝无多余空白
/// - 鼠标悬浮向侧边（自动适配屏幕左右剩余空间）展开子菜单，带防误触过渡延迟
/// - 单选后仅关闭当前级面板、父级保持打开；Esc 逐级关闭；点击外部关闭全部
final class CascadingMenuController {
    private struct LevelEntry {
        let level: Int
        let route: MenuRoute?
        let panel: MenuPanel
        let hostingView: NSHostingView<AnyView>
        let expandedLeft: Bool
        var sizeObservation: NSKeyValueObservation?
    }

    private let core: CoreManager
    private let profileStore: ProfileStore
    private let coreVersion: CoreVersionMonitor
    private let wiFiAutoSwitch: WiFiAutoSwitch
    private let launchAtLogin: LaunchAtLogin
    private let windowOpener: WindowOpener
    private let coordinator = MenuCoordinator()

    private var statusItem: NSStatusItem?
    private var entries: [LevelEntry] = []
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var closeTargetLevel: Int?
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    init(
        core: CoreManager,
        profileStore: ProfileStore,
        coreVersion: CoreVersionMonitor,
        wiFiAutoSwitch: WiFiAutoSwitch,
        launchAtLogin: LaunchAtLogin,
        windowOpener: WindowOpener
    ) {
        self.core = core
        self.profileStore = profileStore
        self.coreVersion = coreVersion
        self.wiFiAutoSwitch = wiFiAutoSwitch
        self.launchAtLogin = launchAtLogin
        self.windowOpener = windowOpener
        self.coordinator.controller = self

        // 等待 NSApplication 初始化完成后挂载状态栏图标
        Task { @MainActor [weak self] in
            self?.setUpStatusItem()
        }
    }

    private func setUpStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(toggleRootMenu(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("MissingBox")
        }
        statusItem = item
        observeIconState()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    /// 随内核类型与 TUN 开关自动更新状态栏模板图标（2×2 组合）
    private func observeIconState() {
        let (activeCore, isTunEnabled) = withObservationTracking {
            (core.activeCore, core.isTunEnabled)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeIconState()
            }
        }

        let resource: ImageResource = switch (activeCore, isTunEnabled) {
        case (.mihomo, false): .menuBarIcon
        case (.mihomo, true): .menuBarIconTun
        case (.singBox, false): .menuBarIconSingBox
        case (.singBox, true): .menuBarIconSingBoxTun
        }
        let image = NSImage(resource: resource)
        image.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func toggleRootMenu(_ sender: AnyObject?) {
        if entries.isEmpty {
            openRootMenu()
        } else {
            closeAll()
        }
    }

    private func openRootMenu() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonScreenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let (panel, hostingView) = makePanel(level: 0, route: nil)
        let size = panel.frame.size
        let visibleFrame = visibleScreenFrame(for: buttonScreenRect)

        // 贴紧状态栏图标下方，优先左对齐图标并限制在屏幕可见区域内
        let x = clamp(buttonScreenRect.minX, min: visibleFrame.minX + 8, max: visibleFrame.maxX - size.width - 8)
        let y = max(visibleFrame.minY + 8, buttonScreenRect.minY - 4 - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        var entry = LevelEntry(level: 0, route: nil, panel: panel, hostingView: hostingView, expandedLeft: false)
        entry.sizeObservation = observePanelSize(panel: panel, hostingView: hostingView, visibleFrame: visibleFrame)
        entries = [entry]
        syncRoutes()

        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installMonitors()
    }

    /// 安排展开下级子菜单（悬浮带 110ms 防闪烁延迟，点击立即展开）
    func scheduleOpenSubmenu(_ route: MenuRoute, fromLevel parentLevel: Int, rowScreenRect: NSRect, immediate: Bool) {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        closeTargetLevel = nil

        let targetLevel = parentLevel + 1
        // 相同路由已展开时无需重建，只需关闭其更深子级
        if let existing = entries.first(where: { $0.level == targetLevel }), existing.route == route {
            if entries.contains(where: { $0.level > targetLevel }) {
                scheduleCloseDeeper(than: targetLevel)
            }
            return
        }

        if immediate {
            openSubmenu(route, fromLevel: parentLevel, rowScreenRect: rowScreenRect)
            return
        }

        hoverOpenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard let self, !Task.isCancelled else { return }
            self.openSubmenu(route, fromLevel: parentLevel, rowScreenRect: rowScreenRect)
        }
    }

    private func openSubmenu(_ route: MenuRoute, fromLevel parentLevel: Int, rowScreenRect: NSRect) {
        guard let parentEntry = entries.first(where: { $0.level == parentLevel }) else { return }
        let targetLevel = parentLevel + 1

        // 先关闭同级及更深层的旧子菜单
        closeFrom(level: targetLevel)

        let (panel, hostingView) = makePanel(level: targetLevel, route: route)
        let size = panel.frame.size
        let parentFrame = parentEntry.panel.frame
        let visibleFrame = visibleScreenFrame(for: parentFrame)

        // 自动决定向左或向右展开：尽量沿用父级方向，空间不足时翻转到另一侧
        let overlap: CGFloat = 3
        let canFitRight = parentFrame.maxX - overlap + size.width <= visibleFrame.maxX - 8
        let canFitLeft = parentFrame.minX + overlap - size.width >= visibleFrame.minX + 8

        let preferLeft = parentEntry.expandedLeft || !canFitRight
        let expandedLeft: Bool
        let x: CGFloat
        if preferLeft && canFitLeft {
            expandedLeft = true
            x = parentFrame.minX + overlap - size.width
        } else if canFitRight {
            expandedLeft = false
            x = parentFrame.maxX - overlap
        } else if canFitLeft {
            expandedLeft = true
            x = parentFrame.minX + overlap - size.width
        } else {
            expandedLeft = preferLeft
            x = clamp(parentFrame.minX - size.width, min: visibleFrame.minX + 8, max: visibleFrame.maxX - size.width - 8)
        }

        // 顶部与父级触发行齐平（向上微调 6pt 以对齐内边距），超出屏幕上下边界时自动钳制
        let desiredTop = rowScreenRect.maxY + 6
        let maxTop = visibleFrame.maxY - 8
        let minTop = visibleFrame.minY + 8 + size.height
        let top = clamp(desiredTop, min: min(minTop, maxTop), max: maxTop)
        let y = max(visibleFrame.minY + 8, top - size.height)

        panel.setFrameOrigin(NSPoint(x: x, y: y))

        var entry = LevelEntry(level: targetLevel, route: route, panel: panel, hostingView: hostingView, expandedLeft: expandedLeft)
        entry.sizeObservation = observePanelSize(panel: panel, hostingView: hostingView, visibleFrame: visibleFrame)
        entries.append(entry)
        syncRoutes()

        panel.orderFrontRegardless()
    }

    /// 鼠标悬浮到普通行上，延迟 220ms 关闭更深层子菜单（期间若鼠标滑入子菜单则自动取消）
    func scheduleCloseDeeper(than level: Int) {
        hoverOpenTask?.cancel()
        let targetLevel = level + 1
        guard entries.contains(where: { $0.level >= targetLevel }) else { return }

        if closeTargetLevel == targetLevel, hoverCloseTask != nil {
            return
        }
        hoverCloseTask?.cancel()
        closeTargetLevel = targetLevel
        hoverCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled else { return }
            self.closeTargetLevel = nil
            self.closeFrom(level: targetLevel)
        }
    }

    func cancelCloseIfEntering(level: Int) {
        if let closeTargetLevel, level >= closeTargetLevel {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
            self.closeTargetLevel = nil
        }
    }

    /// 关闭指定层级及所有更深子级，保留父级菜单打开
    func closeFrom(level: Int) {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        closeTargetLevel = nil

        let toRemove = entries.filter { $0.level >= level }
        guard !toRemove.isEmpty else { return }
        for entry in toRemove.reversed() {
            entry.sizeObservation?.invalidate()
            entry.panel.orderOut(nil)
        }
        entries.removeAll { $0.level >= level }
        syncRoutes()

        if entries.isEmpty {
            finishClosingAll()
        }
    }

    /// 关闭最深的一层菜单（供 Esc 键逐级返回使用）
    func closeDeepest() {
        guard let deepest = entries.last else { return }
        if deepest.level == 0 {
            closeAll()
        } else {
            closeFrom(level: deepest.level)
        }
    }

    /// 关闭全部菜单
    func closeAll() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        closeTargetLevel = nil

        for entry in entries.reversed() {
            entry.sizeObservation?.invalidate()
            entry.panel.orderOut(nil)
        }
        entries.removeAll()
        syncRoutes()
        finishClosingAll()
    }

    private func finishClosingAll() {
        statusItem?.button?.highlight(false)
        removeMonitors()
    }

    func openAppWindow(id: String) {
        closeAll()
        windowOpener.open(id: id)
    }

    func openAppWindow<Value: Codable & Hashable>(id: String, value: Value) {
        closeAll()
        windowOpener.open(id: id, value: value)
    }

    // MARK: - 面板构造与尺寸自适应

    private func makePanel(level: Int, route: MenuRoute?) -> (MenuPanel, NSHostingView<AnyView>) {
        let rootView = AnyView(
            MenuLevelView(
                level: level,
                route: route,
                core: core,
                profileStore: profileStore,
                coreVersion: coreVersion,
                wiFiAutoSwitch: wiFiAutoSwitch,
                launchAtLogin: launchAtLogin,
                coordinator: coordinator
            )
            .environment(\.controlActiveState, .active)
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true
        visualEffect.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        // 先计算一次固有尺寸，使面板首帧即精确贴合内容高度
        let fittingSize = hostingView.fittingSize
        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: fittingSize))
        panel.contentView = visualEffect
        panel.setContentSize(fittingSize)

        return (panel, hostingView)
    }

    /// 监听 SwiftUI 内容尺寸变化（如订阅更新后条目增减），保持面板顶部锚点不动、向下自然伸缩
    private func observePanelSize(
        panel: MenuPanel,
        hostingView: NSHostingView<AnyView>,
        visibleFrame: NSRect
    ) -> NSKeyValueObservation {
        hostingView.observe(\.frame, options: [.new]) { [weak panel] view, _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                let newSize = view.fittingSize
                guard newSize.width > 0, newSize.height > 0 else { return }
                let oldFrame = panel.frame
                guard abs(oldFrame.width - newSize.width) > 0.5 || abs(oldFrame.height - newSize.height) > 0.5 else {
                    return
                }
                let top = oldFrame.maxY
                let newY = max(visibleFrame.minY + 8, top - newSize.height)
                panel.setFrame(NSRect(x: oldFrame.origin.x, y: newY, width: newSize.width, height: newSize.height), display: true)
            }
        }
    }

    private func syncRoutes() {
        coordinator.syncActiveRoutes(from: entries.map { ($0.level, $0.route) })
    }

    // MARK: - 全局与本地事件监听

    private func installMonitors() {
        removeMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeAll()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape：逐级关闭最深子菜单
                    self.closeDeepest()
                    return nil
                }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers?.lowercased() == "q" {
                    self.closeAll()
                    NSApplication.shared.terminate(nil)
                    return nil
                }
                return event
            }

            // 本地鼠标点击落在菜单面板和状态栏按钮之外时收起全部菜单
            let mouseLocation = NSEvent.mouseLocation
            if !self.isPointInsideMenusOrStatusButton(mouseLocation) {
                self.closeAll()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func isPointInsideMenusOrStatusButton(_ screenPoint: NSPoint) -> Bool {
        if entries.contains(where: { $0.panel.frame.contains(screenPoint) }) {
            return true
        }
        if let button = statusItem?.button, let window = button.window {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonRect.contains(screenPoint) {
                return true
            }
        }
        return false
    }

    private func visibleScreenFrame(for rect: NSRect) -> NSRect {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else { return minValue }
        return Swift.min(Swift.max(value, minValue), maxValue)
    }
}

/// 无边框、非激活式浮动菜单面板，不抢占前台应用焦点
private final class MenuPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
