//
//  ProxyGroup.swift
//  MissingBox
//

import Foundation

/// 菜单中展示的策略组
nonisolated struct ProxyGroup: Identifiable, Equatable {
    struct Member: Identifiable, Equatable {
        var name: String
        /// 最近一次测速结果，0 表示超时，nil 表示未测速
        var delay: Int?

        var id: String { name }

        var delayText: String? {
            switch delay {
            case nil: nil
            case 0: String(localized: "Timeout")
            case let delay?: "\(delay)ms"
            }
        }
    }

    var name: String
    var now: String?
    /// URLTest、Fallback 被手动锁定的节点（仅 mihomo）
    var fixed: String?
    var members: [Member]
    /// mihomo 允许手动切换 Selector/URLTest/Fallback；sing-box 仅允许切换 Selector
    var isSelectable: Bool

    var id: String { name }

    /// 参考 clash-verge-rev 的托盘菜单：按 GLOBAL 中的顺序（即配置文件顺序）排列，
    /// 全局模式在 GLOBAL 可选时只显示 GLOBAL，其余情况显示除 GLOBAL 外未隐藏的策略组
    static func list(from proxies: [String: CoreController.Proxy], mode: ProxyMode, coreType: CoreType) -> [ProxyGroup] {
        let global = "GLOBAL"
        let useGlobalOnly = mode == .global && (coreType == .mihomo || proxies[global]?.type == "Selector")
        let names: [String]
        if useGlobalOnly {
            names = [global]
        } else {
            let ordered = proxies[global]?.all ?? []
            let rest = proxies.keys.filter { !ordered.contains($0) }.sorted()
            names = (ordered + rest).filter { $0 != global }
        }

        return names.compactMap { name in
            guard let proxy = proxies[name], let all = proxy.all, !all.isEmpty, proxy.hidden != true else { return nil }
            let members = all.map { Member(name: $0, delay: delay(of: $0, testURL: proxy.testUrl, in: proxies)) }
            let isSelectable = coreType.selectableGroupTypes.contains(proxy.type)
            let fixed = coreType.supportsUnfixProxy ? proxy.fixed.flatMap { $0.isEmpty ? nil : $0 } : nil
            return ProxyGroup(name: name, now: proxy.now, fixed: fixed, members: members, isSelectable: isSelectable)
        }
    }

    /// 内核不会为策略组记录延迟，沿 now 找到实际选中的节点。
    /// 内核按测速 URL 分别记录延迟，优先取所在策略组 URL 下的结果，再退回默认记录
    private static func delay(of name: String, testURL: String?, in proxies: [String: CoreController.Proxy]) -> Int? {
        var current = name
        var testURL = testURL
        for _ in 0..<8 {
            guard let proxy = proxies[current] else { return nil }
            guard proxy.all != nil, let now = proxy.now, !now.isEmpty, now != current else {
                let history = testURL.flatMap { proxy.extra?[$0]?.history }.flatMap { $0.isEmpty ? nil : $0 } ?? proxy.history
                return history?.last?.delay
            }
            // 嵌套策略组中的节点由该组按自己的 URL 测速
            if let url = proxy.testUrl, !url.isEmpty {
                testURL = url
            }
            current = now
        }
        return nil
    }
}
