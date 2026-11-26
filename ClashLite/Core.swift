//
//  Core.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import AppKit
import Observation
import os

/// 支持的内核类型；各内核的二进制共用 Core/ 目录，工作目录、配置与覆写彼此隔离
nonisolated enum CoreType: String, CaseIterable, Identifiable, Codable {
    case mihomo
    case singBox = "sing-box"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .mihomo: "mihomo"
        case .singBox: "sing-box"
        }
    }

    var binaryName: String { rawValue }

    var binaryURL: URL {
        CoreDirectory.url.appending(path: binaryName, directoryHint: .notDirectory)
    }

    /// 内核工作目录，存放 Geo 数据、规则集、缓存、面板等；mihomo 保持原路径兼容旧版本
    var homeURL: URL {
        let name = switch self {
        case .mihomo: "Home"
        case .singBox: "Home-sing-box"
        }
        return CoreDirectory.appSupportURL.appending(path: name, directoryHint: .isDirectory)
    }

    /// 内核输出日志，每次启动时清空
    var logURL: URL {
        homeURL.appending(path: "\(binaryName).log", directoryHint: .notDirectory)
    }

    /// 配置文件目录
    var profilesURL: URL {
        let name = switch self {
        case .mihomo: "Profiles"
        case .singBox: "Profiles-sing-box"
        }
        return CoreDirectory.appSupportURL.appending(path: name, directoryHint: .isDirectory)
    }

    /// 配置覆写目录
    var overridesURL: URL {
        let name = switch self {
        case .mihomo: "Overrides"
        case .singBox: "Overrides-sing-box"
        }
        return CoreDirectory.appSupportURL.appending(path: name, directoryHint: .isDirectory)
    }

    /// 全局覆写文件
    var globalOverrideURL: URL {
        let name = switch self {
        case .mihomo: "Override.yaml"
        case .singBox: "Override-sing-box.json"
        }
        return CoreDirectory.appSupportURL.appending(path: name, directoryHint: .notDirectory)
    }

    var profileFileExtensions: Set<String> {
        switch self {
        case .mihomo: ["yaml", "yml"]
        case .singBox: ["json"]
        }
    }

    var defaultProfileExtension: String {
        switch self {
        case .mihomo: "yaml"
        case .singBox: "json"
        }
    }

    /// 下载订阅时携带的 User-Agent，使订阅服务返回对应格式的配置
    var subscriptionUserAgent: String {
        switch self {
        case .mihomo: "clash.meta"
        case .singBox: "sing-box"
        }
    }

    /// 各自保存选中的配置名称，切换内核时互不影响
    var selectedProfileKey: String {
        switch self {
        case .mihomo: "selectedProfileName"
        case .singBox: "selectedSingBoxProfileName"
        }
    }

    /// 是否支持通过 PUT /configs 热重载完整配置
    var supportsHotReload: Bool {
        self == .mihomo
    }

    /// 是否支持通过 DELETE /proxies/{group} 解除 URLTest/Fallback 锁定
    var supportsUnfixProxy: Bool {
        self == .mihomo
    }

    /// GET /configs 是否返回真实的 TUN 状态和代理端口
    var supportsRemoteTunSync: Bool {
        self == .mihomo
    }

    /// 系统 DNS 变化后是否需要重载以清除内核缓存
    var needsDNSChangeReload: Bool {
        self == .mihomo
    }

    /// 菜单栏中允许手动切换节点的策略组类型
    var selectableGroupTypes: Set<String> {
        switch self {
        case .mihomo: ["Selector", "URLTest", "Fallback"]
        case .singBox: ["Selector"]
        }
    }
}

nonisolated enum CoreDirectory {
    /// ~/Library/Application Support/<Bundle ID>
    static var appSupportURL: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "ClashLite", directoryHint: .isDirectory)
    }

    /// ~/Library/Application Support/<Bundle ID>/Core
    /// 启用 App Sandbox 时会被重定向到 ~/Library/Containers/<Bundle ID>/Data/Library/Application Support/...
    static var url: URL {
        appSupportURL.appending(path: "Core", directoryHint: .isDirectory)
    }

    @discardableResult
    static func createIfNeeded(for coreType: CoreType = .mihomo) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: coreType.homeURL, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("创建内核目录失败：\(error)")
            return false
        }
    }

    @MainActor
    static func open() {
        guard createIfNeeded() else { return }
        NSWorkspace.shared.open(url)
    }

    /// 自带内核的版本把各内核可执行文件放在 Resources 中，内核目录中缺少对应文件时复制过去；
    /// 已有文件时不覆盖，以免替换用户自己放入的版本
    static func installBundledIfNeeded() {
        for coreType in CoreType.allCases {
            let destination = coreType.binaryURL
            guard let bundled = Bundle.main.url(forResource: coreType.binaryName, withExtension: nil),
                  !FileManager.default.fileExists(atPath: destination.path),
                  createIfNeeded(for: coreType)
            else { continue }

            // 先复制到临时文件再移动，避免版本监听读到不完整的文件
            let temporary = url.appending(path: ".\(coreType.binaryName)-\(UUID().uuidString)", directoryHint: .notDirectory)
            do {
                try FileManager.default.copyItem(at: bundled, to: temporary)
                // 从未移除隔离属性的应用中复制出来时会带上隔离属性
                removexattr(temporary.path, "com.apple.quarantine", 0)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                NSLog("复制自带内核 \(coreType.displayName) 失败：\(error)")
            }
        }
    }
}

nonisolated enum CoreLog {
    /// 取输出中最后一条错误：
    /// - mihomo：`level=fatal msg="Parse config error: ..."`
    /// - sing-box：`FATAL[0000] decode config at stdin: ...`
    static func lastError(in text: String, for coreType: CoreType = .mihomo) -> String? {
        switch coreType {
        case .mihomo:
            let line = text.split(whereSeparator: \.isNewline).last {
                $0.contains("level=fatal") || $0.contains("level=error")
            }
            guard let line, let start = line.range(of: "msg=\"") else { return nil }
            var message = line[start.upperBound...]
            if message.hasSuffix("\"") {
                message = message.dropLast()
            }
            return message.replacingOccurrences(of: "\\\"", with: "\"")

        case .singBox:
            let cleaned = stripANSI(text)
            let line = cleaned.split(whereSeparator: \.isNewline).last {
                $0.contains("FATAL[") || $0.contains("FATAL [") || $0.contains("ERROR[") || $0.contains("ERROR [")
            }
            guard let line else { return nil }
            let marker = line.range(of: "FATAL[")
                ?? line.range(of: "FATAL [")
                ?? line.range(of: "ERROR[")
                ?? line.range(of: "ERROR [")
            if let marker,
               let closing = line[marker.upperBound...].firstIndex(of: "]") {
                let message = line[line.index(after: closing)...].trimmingCharacters(in: .whitespaces)
                return message.isEmpty ? nil : message
            }
            return String(line).trimmingCharacters(in: .whitespaces)
        }
    }

    /// 去除终端 ANSI 转义序列，避免日志含颜色码时影响解析
    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{001B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}

/// 记录当前进程正在运行的短生命周期辅助子进程（版本读取、配置校验），
/// 避免启动内核时的残留清理将其误杀（setuid root 子进程无法用 proc_pidinfo 查父 PID）
nonisolated enum CoreHelperProcesses {
    private static let lock = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    static func run(_ process: Process) throws -> pid_t {
        try lock.withLock { pids in
            try process.run()
            let pid = process.processIdentifier
            pids.insert(pid)
            return pid
        }
    }

    static func unregister(_ pid: pid_t) {
        lock.withLock { _ = $0.remove(pid) }
    }

    static func contains(_ pid: pid_t) -> Bool {
        lock.withLock { $0.contains(pid) }
    }
}

/// 读取各内核版本，并监听内核目录变化以自动刷新
@Observable
final class CoreVersionMonitor {
    private(set) var versions: [CoreType: String] = [:]

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        startMonitoring()
        refresh()
    }

    func version(for coreType: CoreType) -> String? {
        versions[coreType]
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let updated = await withTaskGroup(of: (CoreType, String?).self) { group in
                for coreType in CoreType.allCases {
                    group.addTask { (coreType, await Self.readVersion(of: coreType)) }
                }
                var results: [CoreType: String] = [:]
                for await (coreType, version) in group {
                    if let version {
                        results[coreType] = version
                    }
                }
                return results
            }
            guard !Task.isCancelled else { return }
            self.versions = updated
        }
    }

    private func startMonitoring() {
        guard CoreDirectory.createIfNeeded() else { return }
        let fd = open(CoreDirectory.url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    /// mihomo 执行 `-v`，sing-box 执行 `version -n`
    @concurrent
    private nonisolated static func readVersion(of coreType: CoreType) async -> String? {
        let binary = coreType.binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = binary
        process.arguments = switch coreType {
        case .mihomo: ["-v"]
        case .singBox: ["version", "-n"]
        }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let pid: pid_t
        do {
            pid = try CoreHelperProcesses.run(process)
        } catch {
            NSLog("运行内核 \(coreType.displayName) 失败：\(error)")
            return nil
        }
        defer { CoreHelperProcesses.unregister(pid) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            NSLog("读取内核 \(coreType.displayName) 版本失败：status=\(process.terminationStatus), reason=\(process.terminationReason.rawValue)")
            return nil
        }

        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch coreType {
        case .mihomo:
            let fields = output.split(whereSeparator: \.isWhitespace)
            return fields.count > 2 ? String(fields[2]) : nil
        case .singBox:
            let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init)
            return firstLine?.isEmpty == false ? firstLine : nil
        }
    }
}
