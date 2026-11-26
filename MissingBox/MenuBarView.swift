//
//  MenuBarView.swift
//  MissingBox
//

import AppKit
import SwiftUI

/// 每一级悬浮级联菜单的内容视图：
/// - 高度严格贴合本级条目数量，仅超长列表才启用滚动
/// - 鼠标悬浮带 `›` 的条目向侧边弹出下级浮窗，单选后只关闭当前级浮窗、保留父级打开
struct MenuLevelView: View {
    let level: Int
    let route: MenuRoute?

    var core: CoreManager
    var profileStore: ProfileStore
    var coreVersion: CoreVersionMonitor
    var wiFiAutoSwitch: WiFiAutoSwitch
    var launchAtLogin: LaunchAtLogin
    var coordinator: MenuCoordinator

    /// 自动更新间隔选项（小时），nil 表示关闭
    private static let autoUpdateIntervals: [Int?] = [nil, 6, 12, 24, 72]

    /// 已删除的配置不可编辑或查看详情
    private var currentProfile: Profile? {
        profileStore.selected.flatMap { $0.isDeleted ? nil : $0 }
    }

    private var activeCoreIcon: Image {
        core.activeCore == .mihomo
            ? Image(core.isTunEnabled ? .menuBarIconTun : .menuBarIcon)
            : Image(core.isTunEnabled ? .menuBarIconSingBoxTun : .menuBarIconSingBox)
    }

    private var statusColor: Color {
        switch core.status {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var proxyGroupsSummary: String? {
        guard !core.proxyGroups.isEmpty else { return nil }
        return core.proxyGroups.first?.now ?? "\(core.proxyGroups.count)"
    }

    private var activeCoreSummary: String {
        if let version = coreVersion.version(for: core.activeCore) {
            return "\(core.activeCore.displayName) \(version)"
        }
        return core.activeCore.displayName
    }

    private var ipv6Summary: String {
        switch core.ipv6Mode {
        case .auto:
            core.isSystemIPv6Available
                ? String(localized: "Auto (On)")
                : String(localized: "Auto (Off)")
        case .enabled:
            IPv6Mode.enabled.title
        case .disabled:
            IPv6Mode.disabled.title
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var panelWidth: CGFloat {
        switch route {
        case nil: 276
        case .ipv6: 200
        case .proxyGroups: 248
        case .proxyGroup: 260
        case .profiles: 256
        case .autoUpdate: 176
        case .core: 252
        case .settings: 232
        }
    }

    var body: some View {
        Group {
            switch route {
            case nil:
                rootMenu
            case .ipv6:
                ipv6Menu
            case .proxyGroups:
                proxyGroupsMenu
            case .proxyGroup(let groupName):
                proxyGroupMenu(named: groupName)
            case .profiles:
                profilesMenu
            case .autoUpdate(let profileName):
                autoUpdateMenu(for: profileName)
            case .core:
                coreMenu
            case .settings:
                settingsMenu
            }
        }
        .padding(6)
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onHover { isHovering in
            if isHovering {
                coordinator.hoverPanel(atLevel: level)
            }
        }
    }

    // MARK: - 一级主菜单

    private var rootMenu: some View {
        @Bindable var core = core

        return VStack(alignment: .leading, spacing: 2) {
            statusHeader
                .onHover { if $0 { coordinator.hoverPlainRow(atLevel: level) } }

            MenuDivider()

            // 代理
            MenuSectionHeader("Proxy")

            Picker("Mode", selection: $core.mode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .onHover { if $0 { coordinator.hoverPlainRow(atLevel: level) } }

            MenuToggleRow(
                title: "TUN Mode",
                systemImage: "network.badge.shield.half.filled",
                isOn: Binding(get: { core.isTunEnabled }, set: { core.setTunEnabled($0) }),
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            )

            MenuToggleRow(
                title: "System Proxy",
                systemImage: "globe",
                isOn: Binding(get: { core.isSystemProxyEnabled }, set: { core.setSystemProxyEnabled($0) }),
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            )

            MenuSubmenuRow(
                title: "IPv6",
                systemImage: "network",
                value: ipv6Summary,
                isActive: coordinator.isRouteActive(.ipv6, atParentLevel: level),
                onHoverOpen: { coordinator.hoverSubmenu(.ipv6, fromLevel: level, rowScreenRect: $0) },
                onClickOpen: { coordinator.openSubmenu(.ipv6, fromLevel: level, rowScreenRect: $0) }
            )

            MenuSubmenuRow(
                title: "Proxy Groups",
                systemImage: "point.3.connected.trianglepath.dotted",
                value: proxyGroupsSummary,
                isActive: coordinator.isRouteActive(.proxyGroups, atParentLevel: level),
                onHoverOpen: { coordinator.hoverSubmenu(.proxyGroups, fromLevel: level, rowScreenRect: $0) },
                onClickOpen: { coordinator.openSubmenu(.proxyGroups, fromLevel: level, rowScreenRect: $0) }
            )
            .disabled(core.proxyGroups.isEmpty)

            MenuActionRow(
                title: "Close All Connections",
                systemImage: "xmark.circle",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                core.closeAllConnections()
            }
            .disabled(core.status != .running)

            MenuDivider()

            // 配置与内核
            MenuSubmenuRow(
                title: "Profile",
                systemImage: "doc.text",
                value: profileStore.selected?.displayName ?? String(localized: "None"),
                isActive: coordinator.isRouteActive(.profiles, atParentLevel: level),
                onHoverOpen: { coordinator.hoverSubmenu(.profiles, fromLevel: level, rowScreenRect: $0) },
                onClickOpen: { coordinator.openSubmenu(.profiles, fromLevel: level, rowScreenRect: $0) }
            )

            MenuSubmenuRow(
                title: "Core",
                systemImage: "cpu",
                value: activeCoreSummary,
                isActive: coordinator.isRouteActive(.core, atParentLevel: level),
                onHoverOpen: { coordinator.hoverSubmenu(.core, fromLevel: level, rowScreenRect: $0) },
                onClickOpen: { coordinator.openSubmenu(.core, fromLevel: level, rowScreenRect: $0) }
            )

            MenuDivider()

            // 面板与日志
            MenuSectionHeader("Dashboard & Log")

            HStack(spacing: 4) {
                MenuActionRow(
                    title: "Open Dashboard",
                    systemImage: "arrow.up.forward.app",
                    onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
                ) {
                    core.openPanel()
                    coordinator.closeAll()
                }
                .disabled(core.status != .running || core.isUpdatingPanel)

                if core.activeCore == .singBox {
                    MenuIconButton(
                        systemImage: "key.horizontal",
                        help: "Copy Dashboard Secret"
                    ) {
                        core.copyDashboardSecret()
                    }
                    .onHover { if $0 { coordinator.hoverPlainRow(atLevel: level) } }
                }
            }

            MenuActionRow(
                title: core.isUpdatingPanel ? "Downloading Dashboard…" : "Update Dashboard",
                systemImage: "arrow.down.circle",
                isLoading: core.isUpdatingPanel,
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                core.updatePanel()
            }
            .disabled(core.status != .running || core.isUpdatingPanel)

            MenuActionRow(
                title: "Open Log…",
                systemImage: "terminal",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                coordinator.openAppWindow(id: CoreLogView.windowID)
            }

            MenuDivider()

            // 设置
            MenuSubmenuRow(
                title: "Settings",
                systemImage: "gearshape",
                isActive: coordinator.isRouteActive(.settings, atParentLevel: level),
                onHoverOpen: { coordinator.hoverSubmenu(.settings, fromLevel: level, rowScreenRect: $0) },
                onClickOpen: { coordinator.openSubmenu(.settings, fromLevel: level, rowScreenRect: $0) }
            )

            MenuDivider()

            // 退出
            MenuActionRow(
                title: "Quit MissingBox",
                systemImage: "rectangle.portrait.and.arrow.right",
                trailingText: "⌘Q",
                isTrailingSubtle: true,
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                coordinator.closeAll()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            activeCoreIcon
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(core.status == .running ? Color.accentColor : Color.primary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(core.status == .running ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.07))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: core.activeCore.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)

                    Text(verbatim: core.status.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            MenuIconButton(
                systemImage: "arrow.clockwise",
                help: "Restart Core"
            ) {
                core.restart()
            }
            .disabled(profileStore.selected == nil)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - 二级：IPv6 模式

    private var ipv6Menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(IPv6Mode.allCases) { option in
                MenuSelectionRow(
                    verbatimTitle: option.title,
                    isSelected: core.ipv6Mode == option,
                    trailingText: option == .auto
                        ? (core.isSystemIPv6Available ? String(localized: "IPv6 Available") : String(localized: "IPv6 Unavailable"))
                        : nil,
                    trailingColor: option == .auto && core.isSystemIPv6Available ? .green : .secondary
                ) {
                    core.setIPv6Mode(option)
                    coordinator.closeLevel(level)
                }
            }
        }
    }

    // MARK: - 二级：策略组列表

    private var proxyGroupsMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            if core.proxyGroups.isEmpty {
                emptyRow("None")
            } else {
                boundedList(itemCount: core.proxyGroups.count, maxHeight: 390) {
                    ForEach(core.proxyGroups) { group in
                        let childRoute = MenuRoute.proxyGroup(group.name)
                        MenuSubmenuRow(
                            verbatimTitle: group.name,
                            value: group.now,
                            isPinned: group.fixed != nil,
                            isActive: coordinator.isRouteActive(childRoute, atParentLevel: level),
                            onHoverOpen: { coordinator.hoverSubmenu(childRoute, fromLevel: level, rowScreenRect: $0) },
                            onClickOpen: { coordinator.openSubmenu(childRoute, fromLevel: level, rowScreenRect: $0) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 三级：策略组节点列表

    private func proxyGroupMenu(named groupName: String) -> some View {
        let group = core.proxyGroups.first { $0.name == groupName }

        return VStack(alignment: .leading, spacing: 2) {
            if let group {
                if group.fixed != nil, core.activeCore.supportsUnfixProxy {
                    MenuActionRow(
                        title: "Unpin",
                        systemImage: "pin.slash"
                    ) {
                        core.unfixProxy(in: group.name)
                        coordinator.closeLevel(level)
                    }

                    MenuDivider()
                }

                boundedList(itemCount: group.members.count, maxHeight: 420) {
                    ForEach(group.members) { member in
                        MenuSelectionRow(
                            verbatimTitle: member.name,
                            isSelected: group.now == member.name,
                            trailingText: member.delayText,
                            trailingColor: delayColor(for: member.delay),
                            isMonospacedTrailing: true
                        ) {
                            core.selectProxy(member.name, in: group.name)
                            coordinator.closeLevel(level)
                        }
                        .disabled(!group.isSelectable)
                    }
                }
            } else {
                emptyRow("None")
            }
        }
    }

    // MARK: - 二级：配置管理

    private var profilesMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            if profileStore.profiles.isEmpty {
                emptyRow("None")
            } else {
                boundedList(itemCount: profileStore.profiles.count, maxHeight: 196) {
                    ForEach(profileStore.profiles) { profile in
                        MenuSelectionRow(
                            verbatimTitle: profile.displayName,
                            isSelected: profileStore.selectedName == profile.name,
                            isDimmedTitle: profile.isDeleted,
                            onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
                        ) {
                            profileStore.selectedName = profile.name
                            coordinator.closeLevel(level)
                        }
                    }
                }
            }

            MenuDivider()

            MenuActionRow(
                title: "Add Profile…",
                systemImage: "plus",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                coordinator.openAppWindow(id: AddProfileView.windowID)
            }

            MenuActionRow(
                title: currentProfile?.subscription == nil ? "Edit Profile…" : "View Profile…",
                systemImage: currentProfile?.subscription == nil ? "pencil" : "eye",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                guard let current = currentProfile else { return }
                coordinator.openAppWindow(id: ProfileEditorView.windowID, value: current.name)
            }
            .disabled(currentProfile == nil)

            MenuActionRow(
                title: "Profile Info…",
                systemImage: "info.circle",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                guard let current = currentProfile else { return }
                coordinator.openAppWindow(id: ProfileInfoView.windowID, value: current.name)
            }
            .disabled(currentProfile == nil)

            if let current = currentProfile, let subscription = current.subscription {
                let isUpdating = profileStore.updatingNames.contains(current.name)
                let autoUpdateRoute = MenuRoute.autoUpdate(current.name)

                MenuActionRow(
                    title: isUpdating ? "Updating Profile…" : "Update Profile",
                    systemImage: "arrow.triangle.2.circlepath",
                    trailingText: subscription.updatedAt.formatted(date: .numeric, time: .shortened),
                    isLoading: isUpdating,
                    onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
                ) {
                    let store = profileStore
                    Task { await Self.updateProfile(current, in: store) }
                }
                .disabled(isUpdating)

                MenuSubmenuRow(
                    title: "Auto Update",
                    systemImage: "clock.arrow.2.circlepath",
                    value: Self.intervalTitle(of: subscription.interval),
                    isActive: coordinator.isRouteActive(autoUpdateRoute, atParentLevel: level),
                    onHoverOpen: { coordinator.hoverSubmenu(autoUpdateRoute, fromLevel: level, rowScreenRect: $0) },
                    onClickOpen: { coordinator.openSubmenu(autoUpdateRoute, fromLevel: level, rowScreenRect: $0) }
                )
            }

            MenuActionRow(
                title: "Profile Override…",
                systemImage: "slider.horizontal.3",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                guard let current = currentProfile else { return }
                coordinator.openAppWindow(
                    id: ConfigOverrideView.windowID,
                    value: ConfigOverride.profile(core.activeCore, current.name)
                )
            }
            .disabled(currentProfile == nil)

            MenuActionRow(
                title: "Global Override…",
                systemImage: "gearshape.2",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                coordinator.openAppWindow(
                    id: ConfigOverrideView.windowID,
                    value: ConfigOverride.global(core.activeCore)
                )
            }

            MenuActionRow(
                title: "View Runtime Config…",
                systemImage: "doc.plaintext",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                coordinator.openAppWindow(id: RuntimeConfigView.windowID)
            }
            .disabled(core.runtimeConfig == nil)

            MenuActionRow(
                title: "Switch by Wi-Fi…",
                systemImage: "wifi",
                trailingText: wiFiAutoSwitch.isEnabled ? String(localized: "On") : nil,
                trailingColor: wiFiAutoSwitch.isEnabled ? .accentColor : .secondary,
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                coordinator.openAppWindow(id: WiFiAutoSwitchView.windowID)
            }

            MenuDivider()

            MenuActionRow(
                title: "Open Profiles Folder",
                systemImage: "folder",
                onHoverEnter: { coordinator.hoverPlainRow(atLevel: level) }
            ) {
                ProfileDirectory.open(for: core.activeCore, selecting: profileStore.selected?.fileURL)
                coordinator.closeAll()
            }
        }
    }

    // MARK: - 三级：自动更新间隔

    private func autoUpdateMenu(for profileName: String) -> some View {
        let profile = profileStore.profiles.first { $0.name == profileName && !$0.isDeleted }

        return VStack(alignment: .leading, spacing: 2) {
            if let profile, let subscription = profile.subscription {
                // 订阅建议的间隔可能不在预设选项中
                let options = Self.autoUpdateIntervals.contains(subscription.interval)
                    ? Self.autoUpdateIntervals
                    : Self.autoUpdateIntervals + [subscription.interval]

                ForEach(options, id: \.self) { interval in
                    MenuSelectionRow(
                        verbatimTitle: Self.intervalTitle(of: interval),
                        isSelected: subscription.interval == interval
                    ) {
                        profileStore.setInterval(interval, of: profile)
                        coordinator.closeLevel(level)
                    }
                }
            } else {
                emptyRow("None")
            }
        }
    }

    // MARK: - 二级：内核管理

    private var coreMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CoreType.allCases) { coreType in
                MenuSelectionRow(
                    verbatimTitle: coreType.displayName,
                    isSelected: core.activeCore == coreType,
                    trailingText: coreVersion.version(for: coreType) ?? String(localized: "Not Installed")
                ) {
                    core.switchCore(to: coreType)
                    coordinator.closeLevel(level)
                }
            }

            MenuDivider()

            MenuInfoRow(
                title: "Core Version",
                systemImage: "tag",
                value: coreVersion.version(for: core.activeCore) ?? String(localized: "Not Installed")
            )

            MenuActionRow(
                title: "Restart Core",
                systemImage: "arrow.clockwise"
            ) {
                core.restart()
            }
            .disabled(profileStore.selected == nil)

            MenuActionRow(
                title: "Open Core Folder",
                systemImage: "folder"
            ) {
                CoreDirectory.open()
                coordinator.closeAll()
            }
        }
    }

    // MARK: - 二级：设置

    private var settingsMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuToggleRow(
                title: "Launch at Login",
                systemImage: "power",
                isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
            )

            MenuInfoRow(
                title: "App Version",
                systemImage: "info.circle",
                value: appVersion
            )
        }
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    // MARK: - 辅助方法

    /// 精确按条目数决定是否启用滚动：条数少时直接渲染零多余高度，超过上限时滚动
    @ViewBuilder
    private func boundedList<Content: View>(
        itemCount: Int,
        maxHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let naturalHeight = CGFloat(itemCount) * 28 + CGFloat(max(0, itemCount - 1)) * 2
        if naturalHeight <= maxHeight {
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
            }
            .frame(height: maxHeight)
        }
    }

    private func emptyRow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }

    private func delayColor(for delay: Int?) -> Color {
        switch delay {
        case nil: .secondary
        case 0: .red
        case let ms? where ms < 200: .green
        case let ms? where ms < 500: .orange
        default: .red
        }
    }

    private static func intervalTitle(of interval: Int?) -> String {
        interval.map { String(localized: "Every \($0) hours") } ?? String(localized: "Off")
    }

    private static func updateProfile(_ profile: Profile, in store: ProfileStore) async {
        do {
            try await store.update(profile)
            Notifier.post(id: "profile", title: "Profile Updated", body: profile.name)
        } catch {
            Notifier.post(id: "profile", title: "Failed to Update Profile", body: error.localizedDescription)
        }
    }
}

// MARK: - 菜单基础组件

private struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
    }
}

private struct MenuSectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 1)
    }
}

/// 固定宽度的图标槽，确保所有行的文字起点垂直对齐
private struct MenuRowIcon: View {
    var systemImage: String?
    var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.85)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// 悬停高亮行按钮样式（支持父级展开态常亮）
private struct MenuRowButtonStyle: ButtonStyle {
    var isActive = false
    var onHoverEnter: (() -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        MenuRowButtonBody(
            configuration: configuration,
            isActive: isActive,
            onHoverEnter: onHoverEnter
        )
    }

    private struct MenuRowButtonBody: View {
        let configuration: Configuration
        let isActive: Bool
        let onHoverEnter: (() -> Void)?

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        onHoverEnter?()
                    }
                }
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                return .primary.opacity(0.14)
            }
            if isHovered || isActive {
                return .primary.opacity(0.09)
            }
            return .clear
        }
    }
}

/// 普通操作行
private struct MenuActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var trailingText: String? = nil
    var trailingColor: Color = .secondary
    var isTrailingSubtle = false
    var isLoading = false
    var onHoverEnter: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MenuRowIcon(systemImage: systemImage, isLoading: isLoading)

                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let trailingText {
                    Text(verbatim: trailingText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isTrailingSubtle ? AnyShapeStyle(.tertiary) : AnyShapeStyle(trailingColor))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(MenuRowButtonStyle(onHoverEnter: onHoverEnter))
    }
}

/// 获取行视图真实 AppKit 屏幕坐标的轻量锚点，确保多屏下子菜单精确对齐
private final class RowAnchorBox {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct RowAnchorView: NSViewRepresentable {
    let box: RowAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// 悬浮展开子菜单的行（悬停或点击均弹出侧边下级浮窗，展开期间保持高亮）
private struct MenuSubmenuRow: View {
    private enum Title {
        case localized(LocalizedStringKey)
        case verbatim(String)
    }

    private let title: Title
    private let systemImage: String?
    private let value: String?
    private let isPinned: Bool
    private let isActive: Bool
    private let onHoverOpen: (NSRect) -> Void
    private let onClickOpen: (NSRect) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var anchorBox = RowAnchorBox()

    init(
        title: LocalizedStringKey,
        systemImage: String? = nil,
        value: String? = nil,
        isPinned: Bool = false,
        isActive: Bool,
        onHoverOpen: @escaping (NSRect) -> Void,
        onClickOpen: @escaping (NSRect) -> Void
    ) {
        self.title = .localized(title)
        self.systemImage = systemImage
        self.value = value
        self.isPinned = isPinned
        self.isActive = isActive
        self.onHoverOpen = onHoverOpen
        self.onClickOpen = onClickOpen
    }

    init(
        verbatimTitle: String,
        systemImage: String? = nil,
        value: String? = nil,
        isPinned: Bool = false,
        isActive: Bool,
        onHoverOpen: @escaping (NSRect) -> Void,
        onClickOpen: @escaping (NSRect) -> Void
    ) {
        self.title = .verbatim(verbatimTitle)
        self.systemImage = systemImage
        self.value = value
        self.isPinned = isPinned
        self.isActive = isActive
        self.onHoverOpen = onHoverOpen
        self.onClickOpen = onClickOpen
    }

    var body: some View {
        Button {
            guard isEnabled, let rect = anchorBox.screenRect else { return }
            onClickOpen(rect)
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    MenuRowIcon(systemImage: systemImage)
                }

                titleText
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }

                    if let value {
                        Text(verbatim: value)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(
            MenuRowButtonStyle(isActive: isActive) {
                guard isEnabled, let rect = anchorBox.screenRect else { return }
                onHoverOpen(rect)
            }
        )
        .background(RowAnchorView(box: anchorBox))
    }

    @ViewBuilder
    private var titleText: some View {
        switch title {
        case .localized(let key): Text(key)
        case .verbatim(let text): Text(verbatim: text)
        }
    }
}

/// 单选列表行（左侧勾选标记）
private struct MenuSelectionRow: View {
    let verbatimTitle: String
    let isSelected: Bool
    var trailingText: String? = nil
    var trailingColor: Color = .secondary
    var isMonospacedTrailing = false
    var isDimmedTitle = false
    var onHoverEnter: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 16, height: 16)

                Text(verbatim: verbatimTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(isDimmedTitle ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let trailingText {
                    Text(verbatim: trailingText)
                        .font(isMonospacedTrailing ? .system(size: 11.5).monospacedDigit() : .system(size: 11.5))
                        .foregroundStyle(trailingColor)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(MenuRowButtonStyle(onHoverEnter: onHoverEnter))
    }
}

/// 开关行：点击整行或右侧开关均可原地切换
private struct MenuToggleRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var isOn: Bool
    var onHoverEnter: (() -> Void)? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isOn.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    MenuRowIcon(systemImage: systemImage)

                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            MenuSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered && isEnabled ? Color.primary.opacity(0.09) : .clear)
        )
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHoverEnter?()
            }
        }
    }
}

/// 始终保持系统强调色的胶囊开关，避免在非激活浮窗（nonactivatingPanel）中被 NSSwitch 褪成灰色
private struct MenuSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.2))
                    .frame(width: 28, height: 16)

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .frame(width: 12, height: 12)
                    .padding(2)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
    }
}

/// 只读信息行
private struct MenuInfoRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            MenuRowIcon(systemImage: systemImage)

            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(verbatim: value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }
}

/// 紧凑图标按钮（用于重启、复制密钥等）
private struct MenuIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered && isEnabled ? Color.primary.opacity(0.09) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
        .onHover { isHovered = $0 }
    }
}
