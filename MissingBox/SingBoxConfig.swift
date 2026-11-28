//
//  SingBoxConfig.swift
//  MissingBox
//

import Foundation

enum SingBoxConfigError: LocalizedError {
    case invalidJSON(String)
    case notObject

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): String(localized: "Invalid JSON: \(detail)")
        case .notObject: String(localized: "The content must be a JSON object")
        }
    }
}

/// 标准 JSON 配置与覆写的解析、深度合并与序列化
nonisolated enum SingBoxJSON {
    /// 空白文本返回空对象（用于空覆写文件）
    static func parseObject(_ text: String, allowEmpty: Bool = false) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowEmpty { return [:] }
            throw SingBoxConfigError.notObject
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw SingBoxConfigError.invalidJSON(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw SingBoxConfigError.notObject
        }
        return dictionary
    }

    /// 深度合并：对象逐键递归合并，其余值直接替换；
    /// 数组可用 `+key` 插入到原数组之前、`key+` 追加到原数组之后
    static func merge(_ override: [String: Any], into base: inout [String: Any]) {
        for (key, value) in override {
            if let items = value as? [Any], key.count > 1, key.hasPrefix("+") {
                let name = String(key.dropFirst())
                let existing = base[name] as? [Any] ?? []
                base[name] = items + existing
            } else if let items = value as? [Any], key.count > 1, key.hasSuffix("+") {
                let name = String(key.dropLast())
                let existing = base[name] as? [Any] ?? []
                base[name] = existing + items
            } else if let nested = value as? [String: Any], var existing = base[key] as? [String: Any] {
                merge(nested, into: &existing)
                base[key] = existing
            } else {
                base[key] = value
            }
        }
    }

    static func serialize(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

/// sing-box v1.15 配置渲染：合并配置覆写与全局覆写后，注入 Clash API（供菜单栏控制）、
/// 原生 API 服务（托管官方 sing-box-dashboard）、TUN 入站及 IPv6 策略，并提取本地代理端口
nonisolated struct SingBoxConfig {
    static let defaultDashboardURL = "https://github.com/SagerNet/sing-box-dashboard/archive/refs/heads/gh-pages.zip"
    private static let apiServiceTag = "clashlite-api"
    private static let defaultTunIPv4Address = "172.18.0.1/30"
    private static let defaultTunIPv6Address = "fdfe:dcba:9876::1/126"

    var mode: ProxyMode
    var isTunEnabled: Bool
    var isIPv6Enabled: Bool
    var controller: CoreController

    func render(profileURL: URL) throws -> CoreConfig.Rendered {
        let text: String
        do {
            text = try String(contentsOf: profileURL, encoding: .utf8)
        } catch {
            NSLog("读取配置失败：\(error)")
            throw CoreConfigError.readFailed
        }

        var root = try SingBoxJSON.parseObject(text)
        let name = profileURL.deletingPathExtension().lastPathComponent
        try ConfigOverride.profile(.singBox, name).apply(to: &root)
        try ConfigOverride.global(.singBox).apply(to: &root)

        applyClashModeRules(to: &root)
        applyClashAPI(to: &root)
        let dashboardDownloadURL = applyAPIService(to: &root)
        applyTun(to: &root)
        applyIPv6(to: &root)

        let ports = extractProxyPorts(from: root)
        let payload = try SingBoxJSON.serialize(root)
        return CoreConfig.Rendered(
            payload: payload,
            uiName: nil,
            proxyPorts: ports,
            dashboardDownloadURL: dashboardDownloadURL
        )
    }

    /// 注入 experimental.clash_api（127.0.0.1:9097），供菜单栏进行模式切换、节点切换与连接管理
    private func applyClashAPI(to root: inout [String: Any]) {
        var experimental = root["experimental"] as? [String: Any] ?? [:]
        var clashAPI = experimental["clash_api"] as? [String: Any] ?? [:]
        clashAPI["external_controller"] = controller.address
        clashAPI["secret"] = controller.secret
        clashAPI["default_mode"] = resolvedDefaultMode(for: .rule, in: root)
        experimental["clash_api"] = clashAPI
        root["experimental"] = experimental
    }

    /// sing-box 仅允许切换到在 route.rules / dns.rules / default_mode 中出现过的 clash_mode；
    /// 若原配置未声明 direct 或 global 规则，则按出站配置自动补全，使菜单栏模式切换生效
    private func applyClashModeRules(to root: inout [String: Any]) {
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        var injected: [[String: Any]] = []

        if !hasClashMode(ProxyMode.direct.rawValue, in: root),
           let directTag = directOutboundTag(in: outbounds) {
            injected.append([
                "clash_mode": ProxyMode.direct.rawValue,
                "outbound": directTag,
            ])
        }

        if !hasClashMode(ProxyMode.global.rawValue, in: root),
           let globalTag = globalOutboundTag(in: root, outbounds: outbounds) {
            injected.append([
                "clash_mode": ProxyMode.global.rawValue,
                "outbound": globalTag,
            ])
        }

        guard !injected.isEmpty else { return }

        var route = root["route"] as? [String: Any] ?? [:]
        var rules = route["rules"] as? [Any] ?? []
        let insertionIndex = rules.lastIndex { isPreModeRule($0) }.map { $0 + 1 } ?? 0
        rules.insert(contentsOf: injected, at: insertionIndex)
        route["rules"] = rules
        root["route"] = route
    }

    private func hasClashMode(_ target: String, in root: [String: Any]) -> Bool {
        let routeRules = (root["route"] as? [String: Any])?["rules"] as? [Any] ?? []
        return findClashMode(matching: target, in: routeRules) != nil
    }

    private func directOutboundTag(in outbounds: [[String: Any]]) -> String? {
        if let direct = outbounds.first(where: { ($0["type"] as? String) == "direct" }),
           let tag = direct["tag"] as? String, !tag.isEmpty {
            return tag
        }
        return outbounds.first { ($0["tag"] as? String) == "direct" }?["tag"] as? String
    }

    private func globalOutboundTag(in root: [String: Any], outbounds: [[String: Any]]) -> String? {
        if let global = outbounds.first(where: { ($0["tag"] as? String) == "GLOBAL" }),
           let tag = global["tag"] as? String {
            return tag
        }
        if let finalTag = (root["route"] as? [String: Any])?["final"] as? String, !finalTag.isEmpty {
            let finalType = outbounds.first { ($0["tag"] as? String) == finalTag }?["type"] as? String
            if finalType != "direct", finalType != "block", finalType != "reject" {
                return finalTag
            }
        }
        if let selector = outbounds.first(where: { ($0["type"] as? String) == "selector" }),
           let tag = selector["tag"] as? String, !tag.isEmpty {
            return tag
        }
        if let urltest = outbounds.first(where: { ($0["type"] as? String) == "urltest" }),
           let tag = urltest["tag"] as? String, !tag.isEmpty {
            return tag
        }
        return nil
    }

    /// DNS 劫持与协议探测须在 clash_mode 分流之前执行
    private func isPreModeRule(_ item: Any) -> Bool {
        guard let rule = item as? [String: Any] else { return false }
        if let action = rule["action"] as? String,
           ["hijack-dns", "sniff", "resolve"].contains(action) {
            return true
        }
        if let proto = rule["protocol"] as? String, proto == "dns" {
            return true
        }
        if let protos = rule["protocol"] as? [String], protos.contains("dns") {
            return true
        }
        return false
    }

    /// 注入 sing-box 原生 API 服务（127.0.0.1:9098），托管官方 sing-box-dashboard；
    /// 保留用户在配置中自定义的 download_url、http_client、update_interval 等字段
    private func applyAPIService(to root: inout [String: Any]) -> String {
        var services = root["services"] as? [[String: Any]] ?? []
        let existingIndex = services.firstIndex { ($0["type"] as? String) == "api" }
        var service = existingIndex.map { services[$0] } ?? [:]

        service["type"] = "api"
        if (service["tag"] as? String)?.isEmpty ?? true {
            service["tag"] = Self.apiServiceTag
        }
        service["listen"] = CoreController.host
        service["listen_port"] = CoreController.singBoxAPIPort
        service["secret"] = controller.secret

        var dashboard = service["dashboard"] as? [String: Any] ?? [:]
        dashboard["enabled"] = true
        dashboard["path"] = controller.uiPath
        if (dashboard["update_interval"] as? String)?.isEmpty ?? true {
            dashboard["update_interval"] = "1d"
        }
        let downloadURL = (dashboard["download_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultDashboardURL
        service["dashboard"] = dashboard

        if let existingIndex {
            services[existingIndex] = service
        } else {
            services.append(service)
        }
        root["services"] = services
        return downloadURL
    }

    /// 关闭 TUN 时移除所有 tun 入站；开启时保留配置自带的 tun 入站，缺失时按 v1.15 规范注入（不设已废弃的 stack）
    private func applyTun(to root: inout [String: Any]) {
        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        if !isTunEnabled {
            inbounds.removeAll { ($0["type"] as? String) == "tun" }
            root["inbounds"] = inbounds
            return
        }

        let hasTun = inbounds.contains { ($0["type"] as? String) == "tun" }
        if !hasTun {
            let addresses = isIPv6Enabled
                ? [Self.defaultTunIPv4Address, Self.defaultTunIPv6Address]
                : [Self.defaultTunIPv4Address]
            let tunInbound: [String: Any] = [
                "type": "tun",
                "tag": "tun-in",
                "address": addresses,
                "auto_route": true,
                "strict_route": true,
            ]
            inbounds.append(tunInbound)
            root["inbounds"] = inbounds
        }
    }

    /// 关闭 IPv6 时剥离 TUN 的 IPv6 地址（防止 auto_route 注入全网 IPv6 路由），
    /// 并强制 DNS 与出站域名解析仅使用 IPv4；开启时保持配置原有双栈设置
    private func applyIPv6(to root: inout [String: Any]) {
        guard !isIPv6Enabled else { return }

        if var inbounds = root["inbounds"] as? [[String: Any]] {
            for index in inbounds.indices where (inbounds[index]["type"] as? String) == "tun" {
                var tun = inbounds[index]
                if let addresses = tun["address"] as? [String] {
                    let ipv4Only = addresses.filter { !$0.contains(":") }
                    tun["address"] = ipv4Only.isEmpty ? [Self.defaultTunIPv4Address] : ipv4Only
                } else if let address = tun["address"] as? String, address.contains(":") {
                    tun["address"] = [Self.defaultTunIPv4Address]
                }
                tun.removeValue(forKey: "inet6_address")
                inbounds[index] = tun
            }
            root["inbounds"] = inbounds
        }

        if var dns = root["dns"] as? [String: Any] {
            dns["strategy"] = "ipv4_only"

            if var servers = dns["servers"] as? [[String: Any]] {
                for index in servers.indices {
                    var server = servers[index]
                    if (server["type"] as? String) == "fakeip" {
                        server.removeValue(forKey: "inet6_range")
                    }
                    if let resolver = server["domain_resolver"] {
                        server["domain_resolver"] = forceIPv4DomainResolver(resolver)
                    }
                    servers[index] = server
                }
                dns["servers"] = servers
            }

            var rules = dns["rules"] as? [[String: Any]] ?? []
            for index in rules.indices where rules[index]["strategy"] != nil {
                rules[index]["strategy"] = "ipv4_only"
            }
            let rejectAAAA: [String: Any] = [
                "query_type": "AAAA",
                "action": "reject",
            ]
            rules.insert(rejectAAAA, at: 0)
            dns["rules"] = rules
            root["dns"] = dns
        }

        if var route = root["route"] as? [String: Any] {
            if let resolver = route["default_domain_resolver"] {
                route["default_domain_resolver"] = forceIPv4DomainResolver(resolver)
            }
            if var rules = route["rules"] as? [[String: Any]] {
                for index in rules.indices where rules[index]["strategy"] != nil {
                    rules[index]["strategy"] = "ipv4_only"
                }
                route["rules"] = rules
            }
            root["route"] = route
        }

        if var outbounds = root["outbounds"] as? [[String: Any]] {
            for index in outbounds.indices {
                var outbound = outbounds[index]
                if let resolver = outbound["domain_resolver"] {
                    outbound["domain_resolver"] = forceIPv4DomainResolver(resolver)
                }
                if outbound["domain_strategy"] != nil {
                    outbound["domain_strategy"] = "ipv4_only"
                }
                outbounds[index] = outbound
            }
            root["outbounds"] = outbounds
        }
    }

    private func forceIPv4DomainResolver(_ value: Any) -> Any {
        if let server = value as? String {
            return ["server": server, "strategy": "ipv4_only"]
        }
        if var object = value as? [String: Any] {
            object["strategy"] = "ipv4_only"
            return object
        }
        return value
    }

    /// sing-box 的 GET /configs 不返回真实监听端口，直接从最终配置的 inbounds 提取供系统代理使用
    private func extractProxyPorts(from root: [String: Any]) -> ProxyPorts? {
        guard let inbounds = root["inbounds"] as? [[String: Any]] else { return nil }

        var mixedPort: Int?
        var httpPort: Int?
        var socksPort: Int?

        for inbound in inbounds {
            guard let type = inbound["type"] as? String,
                  let port = (inbound["listen_port"] as? NSNumber)?.intValue,
                  port > 0
            else { continue }

            switch type {
            case "mixed" where mixedPort == nil:
                mixedPort = port
            case "http" where httpPort == nil:
                httpPort = port
            case "socks" where socksPort == nil:
                socksPort = port
            default:
                break
            }
        }

        let http = mixedPort ?? httpPort
        let socks = mixedPort ?? socksPort
        guard http != nil || socks != nil else { return nil }
        return ProxyPorts(http: http, socks: socks)
    }

    /// 若路由或 DNS 规则中已用大小写形式声明了 clash_mode（如 "Rule"/"Global"/"Direct"），
    /// 沿用规则中的拼写，避免面板中出现大小写重复的模式项
    private func resolvedDefaultMode(for targetMode: ProxyMode, in root: [String: Any]) -> String {
        let target = targetMode.rawValue
        let ruleSources: [[Any]] = [
            (root["route"] as? [String: Any])?["rules"] as? [Any] ?? [],
            (root["dns"] as? [String: Any])?["rules"] as? [Any] ?? [],
        ]
        for rules in ruleSources {
            if let matched = findClashMode(matching: target, in: rules) {
                return matched
            }
        }
        return target
    }

    private func findClashMode(matching target: String, in rules: [Any]) -> String? {
        for item in rules {
            guard let rule = item as? [String: Any] else { continue }
            if let value = rule["clash_mode"] as? String, value.lowercased() == target {
                return value
            }
            if let nested = rule["rules"] as? [Any], let matched = findClashMode(matching: target, in: nested) {
                return matched
            }
        }
        return nil
    }
}
