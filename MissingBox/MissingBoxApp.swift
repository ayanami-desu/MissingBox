//
//  MissingBoxApp.swift
//  MissingBox
//

import SwiftUI

nonisolated enum ProxyMode: String, CaseIterable, Identifiable, Codable {
    case rule
    case global
    case direct

    var id: Self { self }

    var title: String {
        switch self {
        case .rule: String(localized: "Rule")
        case .global: String(localized: "Global")
        case .direct: String(localized: "Direct")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 注销、关机等由系统发出的退出请求不弹窗，避免阻塞
        if NSAppleEventManager.shared().currentAppleEvent?.eventID == kAEQuitApplication {
            return .terminateNow
        }

        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Are you sure you want to quit MissingBox?")
        alert.informativeText = String(localized: "The core will stop running after quitting.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct MissingBoxApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var coreVersion: CoreVersionMonitor
    @State private var launchAtLogin: LaunchAtLogin
    @State private var profileStore: ProfileStore
    @State private var wiFiAutoSwitch: WiFiAutoSwitch
    @State private var core: CoreManager
    @State private var windowOpener: WindowOpener
    @State private var menuController: CascadingMenuController

    init() {
        CoreDirectory.installBundledIfNeeded()
        let activeCore = CoreManager.loadStoredCoreType()
        let coreVersion = CoreVersionMonitor()
        let launchAtLogin = LaunchAtLogin()
        let profileStore = ProfileStore(coreType: activeCore)
        // 先按当前 Wi-Fi 选好配置、TUN 和代理模式，内核直接以它们启动
        let wiFiAutoSwitch = WiFiAutoSwitch(profileStore: profileStore)
        let core = CoreManager(profileStore: profileStore, wiFiAutoSwitch: wiFiAutoSwitch)
        wiFiAutoSwitch.attach(core)
        // 手动或自动更新正在使用的订阅后，重新加载内核
        profileStore.onUpdate = { [weak profileStore, weak core] coreType, name in
            if core?.activeCore == coreType, profileStore?.selectedName == name {
                core?.reload()
            }
        }
        profileStore.onRename = { [weak wiFiAutoSwitch] coreType, oldName, newName in
            wiFiAutoSwitch?.renameProfile(for: coreType, from: oldName, to: newName)
        }

        let windowOpener = WindowOpener()
        let menuController = CascadingMenuController(
            core: core,
            profileStore: profileStore,
            coreVersion: coreVersion,
            wiFiAutoSwitch: wiFiAutoSwitch,
            launchAtLogin: launchAtLogin,
            windowOpener: windowOpener
        )

        _coreVersion = State(initialValue: coreVersion)
        _launchAtLogin = State(initialValue: launchAtLogin)
        _profileStore = State(initialValue: profileStore)
        _wiFiAutoSwitch = State(initialValue: wiFiAutoSwitch)
        _core = State(initialValue: core)
        _windowOpener = State(initialValue: windowOpener)
        _menuController = State(initialValue: menuController)
    }

    var body: some Scene {
        let _ = windowOpener.bind(openWindow)

        Window("Add Profile", id: AddProfileView.windowID) {
            AddProfileView()
                .environment(profileStore)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Profile Info", id: ProfileInfoView.windowID, for: String.self) { $name in
            if let name {
                ProfileInfoView(name: name)
                    .environment(profileStore)
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Edit Profile", id: ProfileEditorView.windowID, for: String.self) { $name in
            if let name {
                ProfileEditorView(name: name)
                    .environment(core)
                    .environment(profileStore)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Runtime Config", id: RuntimeConfigView.windowID) {
            RuntimeConfigView()
                .environment(core)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Switch by Wi-Fi", id: WiFiAutoSwitchView.windowID) {
            WiFiAutoSwitchView()
                .environment(wiFiAutoSwitch)
                .environment(core)
                .environment(profileStore)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Core Log", id: CoreLogView.windowID) {
            CoreLogView()
                .environment(core)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Override", id: ConfigOverrideView.windowID, for: ConfigOverride.self) { $target in
            if let target {
                ConfigOverrideView(target: target)
                    .environment(core)
                    .environment(profileStore)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
