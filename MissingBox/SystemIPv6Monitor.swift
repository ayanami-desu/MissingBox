//
//  SystemIPv6Monitor.swift
//  MissingBox
//

import Darwin
import Foundation
import SystemConfiguration

/// 应用层的 IPv6 控制模式：自动模式随物理网络公网 IPv6 状态切换，也可手动强制开/关
nonisolated enum IPv6Mode: String, CaseIterable, Identifiable, Codable {
    case auto
    case enabled
    case disabled

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .enabled: String(localized: "On")
        case .disabled: String(localized: "Off")
        }
    }
}

/// 监听物理网络的公网 IPv6 可用性（忽略 TUN、回环等虚拟接口，以及 fe80:: / fc00::/7 本地地址）
final class SystemIPv6Monitor {
    private static let globalIPv6Key = "State:/Network/Global/IPv6" as CFString
    private static let globalIPv4Key = "State:/Network/Global/IPv4" as CFString
    private static let serviceIPv6Pattern = "State:/Network/Service/.*/IPv6" as CFString
    private nonisolated static let virtualInterfacePrefixes = ["utun", "tun", "lo", "awdl", "llw", "gif", "stf", "anpi"]

    private let onChange: () -> Void
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?

    /// 回调在主线程执行
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<SystemIPv6Monitor>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.onChange()
            }
        }
        guard let store = SCDynamicStoreCreate(nil, "MissingBox" as CFString, callback, &context),
              SCDynamicStoreSetNotificationKeys(
                  store,
                  [Self.globalIPv6Key, Self.globalIPv4Key] as CFArray,
                  [Self.serviceIPv6Pattern] as CFArray
              ),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        else {
            NSLog("监听系统 IPv6 状态失败")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        self.source = source
    }

    deinit {
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
    }

    /// 物理主网络接口是否具备公网 IPv6 路由与全球单播地址（2000::/3）
    var isAvailable: Bool {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, Self.globalIPv6Key) as? [String: Any],
              let interface = global[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
              !interface.isEmpty,
              !Self.isVirtualInterface(interface),
              let router = global[kSCPropNetIPv6Router as String] as? String,
              !router.isEmpty
        else {
            return false
        }

        if let serviceID = global[kSCDynamicStorePropNetPrimaryService as String] as? String,
           let service = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv6" as CFString) as? [String: Any],
           let addresses = service[kSCPropNetIPv6Addresses as String] as? [String],
           addresses.contains(where: Self.isGlobalUnicastIPv6) {
            return true
        }

        return Self.interfaceHasGlobalUnicastIPv6(interface)
    }

    private nonisolated static func isVirtualInterface(_ name: String) -> Bool {
        virtualInterfacePrefixes.contains { name.hasPrefix($0) }
    }

    /// 全球单播 IPv6 地址（2000::/3），排除链路本地 fe80::/10、唯一本地 fc00::/7 与回环 ::1
    private nonisolated static func isGlobalUnicastIPv6(_ addressString: String) -> Bool {
        let bare = addressString.split(separator: "%", maxSplits: 1).first.map(String.init) ?? addressString
        var address = in6_addr()
        guard bare.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        return (address.__u6_addr.__u6_addr8.0 & 0xe0) == 0x20
    }

    private nonisolated static func interfaceHasGlobalUnicastIPv6(_ interfaceName: String) -> Bool {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return false }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            current = entry.ifa_next
            guard let rawName = entry.ifa_name,
                  String(cString: rawName) == interfaceName,
                  let addr = entry.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET6)
            else { continue }

            let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            if (sin6.sin6_addr.__u6_addr.__u6_addr8.0 & 0xe0) == 0x20 {
                return true
            }
        }
        return false
    }
}
