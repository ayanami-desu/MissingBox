//
//  CoreConfig.swift
//  MissingBox
//

import Foundation
import Yams

/// 内核监听的本地代理端口，供系统代理和面板下载使用
nonisolated struct ProxyPorts: Equatable {
    var http: Int?
    var socks: Int?
}

enum CoreConfigError: LocalizedError {
    case readFailed
    case invalidContent

    var errorDescription: String? {
        switch self {
        case .readFailed: String(localized: "Unable to read the profile file")
        case .invalidContent: String(localized: "The profile is not a valid YAML mapping")
        }
    }
}

/// 在配置文件之上依次合并配置覆写、全局覆写和应用内的设置，生成交给内核的最终配置
nonisolated struct CoreConfig {
    var coreType: CoreType
    var mode: ProxyMode
    var isTunEnabled: Bool
    var isIPv6Enabled: Bool
    var controller: CoreController

    /// mihomo 配置未指定面板下载地址时使用的面板
    static let defaultUIURL = "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"

    struct Rendered {
        var payload: String
        /// mihomo 面板所在的子目录（external-ui-name）
        var uiName: String?
        /// sing-box 渲染时直接从 inbounds 提取的代理端口；mihomo 从 GET /configs 读取
        var proxyPorts: ProxyPorts?
        /// sing-box 官方面板下载地址
        var dashboardDownloadURL: String?
    }

    func render(profileURL: URL) throws -> Rendered {
        switch coreType {
        case .mihomo:
            try renderMihomo(profileURL: profileURL)
        case .singBox:
            try SingBoxConfig(
                mode: mode,
                isTunEnabled: isTunEnabled,
                isIPv6Enabled: isIPv6Enabled,
                controller: controller
            )
            .render(profileURL: profileURL)
        }
    }

    private func renderMihomo(profileURL: URL) throws -> Rendered {
        let text: String
        do {
            text = try String(contentsOf: profileURL, encoding: .utf8)
        } catch {
            NSLog("读取配置失败：\(error)")
            throw CoreConfigError.readFailed
        }

        var root = try Self.mapping(from: text)
        // 文件名即配置名称
        let name = profileURL.deletingPathExtension().lastPathComponent
        try ConfigOverride.profile(.mihomo, name).apply(to: &root)
        try ConfigOverride.global(.mihomo).apply(to: &root)

        root["mode"] = Node(mode.rawValue)
        root["external-controller"] = Node(controller.address)
        root["secret"] = Node(controller.secret, .implicit, .doubleQuoted)
        applyUI(to: &root)
        applyIPv6(to: &root)
        applyTun(to: &root)

        let uiName = root["external-ui-name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return Rendered(payload: try Self.serialize(root), uiName: uiName)
    }

    /// 配置须为 YAML 映射
    static func mapping(from text: String) throws -> Node.Mapping {
        guard case .mapping(let root) = try Yams.compose(yaml: text) else {
            throw CoreConfigError.invalidContent
        }
        return root
    }

    static func serialize(_ root: Node.Mapping) throws -> String {
        try Yams.serialize(node: .mapping(root), width: -1, allowUnicode: true)
    }

    /// 面板由内核托管在工作目录中的随机目录下，未指定下载地址时使用 metacubexd
    private func applyUI(to root: inout Node.Mapping) {
        root["external-ui"] = Node(controller.uiPath)
        if root["external-ui-url"]?.string?.isEmpty ?? true {
            root["external-ui-url"] = Node(Self.defaultUIURL)
        }
    }

    /// 按应用内 IPv6 状态同步顶层 ipv6 与 dns.ipv6；关闭时同时移除 tun.inet6-address，避免无 IPv6 网络下产生无效路由
    private func applyIPv6(to root: inout Node.Mapping) {
        root["ipv6"] = Node(String(isIPv6Enabled))
        if var dns = root["dns"]?.mapping {
            dns["ipv6"] = Node(String(isIPv6Enabled))
            root["dns"] = .mapping(dns)
        }
        if !isIPv6Enabled, var tun = root["tun"]?.mapping, tun["inet6-address"] != nil {
            tun["inet6-address"] = nil
            root["tun"] = .mapping(tun)
        }
    }

    /// 参考 clash-verge-rev 的 use_tun：开启 TUN 时确保 DNS 以 fake-ip 模式工作
    private func applyTun(to root: inout Node.Mapping) {
        var tun = root["tun"]?.mapping ?? [:]
        tun["enable"] = Node(String(isTunEnabled))
        root["tun"] = .mapping(tun)

        guard isTunEnabled else { return }

        var dns = root["dns"]?.mapping ?? [:]
        let enhancedMode = dns["enhanced-mode"]?.string
        guard enhancedMode == nil || enhancedMode == "fake-ip" else { return }

        dns["enable"] = Node("true")
        dns["ipv6"] = Node(String(isIPv6Enabled))
        if enhancedMode == nil {
            dns["enhanced-mode"] = Node("fake-ip")
        }
        if dns["fake-ip-range"] == nil {
            dns["fake-ip-range"] = Node("198.18.0.1/16")
        }
        if isIPv6Enabled, dns["fake-ip-range6"] == nil {
            dns["fake-ip-range6"] = Node("2001:2::0/64")
        }
        root["dns"] = .mapping(dns)
    }
}
