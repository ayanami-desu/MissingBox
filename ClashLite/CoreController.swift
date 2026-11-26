//
//  CoreController.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation

enum CoreControllerError: LocalizedError {
    case badStatus(Int, String)
    case invalidDashboardURL
    case dashboardExtractFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let message):
            message.isEmpty ? String(localized: "Core API request failed (HTTP \(code))") : message
        case .invalidDashboardURL:
            String(localized: "Invalid dashboard download URL")
        case .dashboardExtractFailed:
            String(localized: "Unable to extract the dashboard archive")
        }
    }
}

/// 内核的 RESTful API（external-controller）以及 sing-box 原生 API 面板地址
nonisolated struct CoreController {
    static let host = "127.0.0.1"
    static let port = 9097
    /// sing-box 原生 API 服务端口，用于托管官方 sing-box-dashboard
    static let singBoxAPIPort = 9098

    var secret: String
    /// 面板目录（mihomo 为 external-ui，sing-box 为 api.dashboard.path），相对内核工作目录
    var uiPath: String

    var address: String { "\(Self.host):\(Self.port)" }

    private var baseURL: URL { URL(string: "http://\(address)")! }

    /// 首次使用时生成随机密钥和面板目录并保存，使面板中保存的后端在重启后依然有效
    static func load() -> CoreController {
        CoreController(
            secret: stored("controllerSecret") { UUID().uuidString },
            uiPath: stored("externalUIPath") { randomPath() }
        )
    }

    private static func stored(_ key: String, default make: () -> String) -> String {
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
            return value
        }
        let value = make()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    /// 数字和小写字母组成的随机目录名
    private static func randomPath() -> String {
        let characters = "0123456789abcdefghijklmnopqrstuvwxyz"
        return String((0..<16).map { _ in characters.randomElement()! })
    }

    /// 打开内核托管的面板：
    /// - mihomo：通过 metacubexd 的 hash 路由自动传入连接参数
    /// - sing-box：打开原生 API 服务托管的 sing-box-dashboard
    func panelURL(for coreType: CoreType, uiName: String?) -> URL {
        switch coreType {
        case .mihomo:
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.path = uiName.map { "/ui/\($0)/" } ?? "/ui/"
            var route = URLComponents()
            route.queryItems = [
                URLQueryItem(name: "hostname", value: Self.host),
                URLQueryItem(name: "port", value: String(Self.port)),
                URLQueryItem(name: "secret", value: secret),
            ]
            // 路由查询参数中的加号须编码，避免被前端解析为空格。
            let query = route.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B")
            components.percentEncodedFragment = "/setup?\(query)"
            return components.url!

        case .singBox:
            return URL(string: "http://\(Self.host):\(Self.singBoxAPIPort)/dashboard/")!
        }
    }

    /// POST /upgrade/ui，mihomo 从 external-ui-url 重新下载面板
    func upgradeUI() async throws {
        try await send("POST", "/upgrade/ui", timeout: 120)
    }

    /// 下载并解压 sing-box-dashboard 到内核工作目录中的面板目录，无需重启内核；
    /// 优先通过运行中的本地代理下载，失败时回退直连
    @concurrent
    func downloadSingBoxDashboard(from urlString: String, to destination: URL, proxyPorts: ProxyPorts?) async throws {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw CoreControllerError.invalidDashboardURL
        }

        let zipData = try await Self.fetchArchive(from: url, proxyPorts: proxyPorts)
        try Self.extractArchive(zipData, to: destination)
    }

    private static func fetchArchive(from url: URL, proxyPorts: ProxyPorts?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let proxyDictionary = Self.proxyDictionary(for: proxyPorts) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = proxyDictionary
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            if let data = try? await Self.downloadData(for: request, using: session) {
                return data
            }
        }
        return try await Self.downloadData(for: request, using: .shared)
    }

    private static func downloadData(for request: URLRequest, using session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CoreControllerError.badStatus(http.statusCode, "")
        }
        return data
    }

    private static func proxyDictionary(for ports: ProxyPorts?) -> [AnyHashable: Any]? {
        guard let ports else { return nil }
        var dict: [AnyHashable: Any] = [:]
        if let http = ports.http {
            dict[kCFNetworkProxiesHTTPEnable] = true
            dict[kCFNetworkProxiesHTTPProxy] = Self.host
            dict[kCFNetworkProxiesHTTPPort] = http
            dict["HTTPSEnable"] = true
            dict["HTTPSProxy"] = Self.host
            dict["HTTPSPort"] = http
        } else if let socks = ports.socks {
            dict[kCFNetworkProxiesSOCKSEnable] = true
            dict[kCFNetworkProxiesSOCKSProxy] = Self.host
            dict[kCFNetworkProxiesSOCKSPort] = socks
        }
        return dict.isEmpty ? nil : dict
    }

    private static func extractArchive(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "ClashLite-dashboard-\(UUID().uuidString)", directoryHint: .isDirectory)
        let zipURL = staging.appending(path: "dashboard.zip", directoryHint: .notDirectory)
        let unpackedURL = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.createDirectory(at: unpackedURL, withIntermediateDirectories: true)
            try data.write(to: zipURL, options: .atomic)
        } catch {
            NSLog("写入面板压缩包失败：\(error)")
            throw CoreControllerError.dashboardExtractFailed
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, unpackedURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("解压面板失败：\(error)")
            throw CoreControllerError.dashboardExtractFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CoreControllerError.dashboardExtractFailed
        }

        // GitHub 归档压缩包会多包一层仓库目录，解开单层目录后验证 index.html
        let items = (try? fileManager.contentsOfDirectory(
            at: unpackedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        let sourceDir: URL
        if items.count == 1,
           (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            sourceDir = items[0]
        } else {
            sourceDir = unpackedURL
        }

        guard fileManager.fileExists(atPath: sourceDir.appending(path: "index.html").path) else {
            throw CoreControllerError.dashboardExtractFailed
        }

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: sourceDir, to: destination)
        } catch {
            NSLog("替换面板目录失败：\(error)")
            throw CoreControllerError.dashboardExtractFailed
        }
    }

    /// GET /version，返回内核版本
    func version() async throws -> String {
        struct Response: Decodable { var version: String }
        let data = try await send("GET", "/version", timeout: 1)
        return try JSONDecoder().decode(Response.self, from: data).version
    }

    /// 内核当前生效的设置，仅解析需要同步的字段
    struct RuntimeConfig: Decodable {
        struct Tun: Decodable { var enable: Bool }
        var mode: String
        var tun: Tun?
        var mixedPort: Int?
        var port: Int?
        var socksPort: Int?

        private enum CodingKeys: String, CodingKey {
            case mode, tun, port
            case mixedPort = "mixed-port"
            case socksPort = "socks-port"
        }
    }

    /// GET /configs，读取内核当前设置（可能已被面板修改）
    func configs() async throws -> RuntimeConfig {
        let data = try await send("GET", "/configs")
        return try JSONDecoder().decode(RuntimeConfig.self, from: data)
    }

    /// PATCH /configs，仅修改运行中的部分字段
    func patchConfigs(_ body: [String: Any]) async throws {
        try await send("PATCH", "/configs", body: body)
    }

    /// 节点或策略组，策略组才有 all 和 now
    struct Proxy: Decodable {
        struct History: Decodable { var delay: Int }
        struct Extra: Decodable { var history: [History]? }
        var type: String
        var all: [String]?
        var now: String?
        /// URLTest、Fallback 手动锁定的节点，空字符串表示自动选择（仅 mihomo）
        var fixed: String?
        var hidden: Bool?
        var history: [History]?
        /// 按测速 URL 分别记录的结果，策略组自定义了 url 时测速结果只在这里
        var extra: [String: Extra]?
        /// 策略组的测速 URL
        var testUrl: String?
    }

    /// GET /proxies，读取全部节点和策略组
    func proxies() async throws -> [String: Proxy] {
        struct Response: Decodable { var proxies: [String: Proxy] }
        let data = try await send("GET", "/proxies")
        return try JSONDecoder().decode(Response.self, from: data).proxies
    }

    /// PUT /proxies/{group}，切换策略组选中的节点
    func selectProxy(_ name: String, in group: String) async throws {
        try await send("PUT", Self.proxyPath(group), body: ["name": name])
    }

    /// DELETE /proxies/{group}，解除 URLTest、Fallback 的锁定，同时清除内核缓存中的选择（仅 mihomo）
    func unfixProxy(in group: String) async throws {
        try await send("DELETE", Self.proxyPath(group))
    }

    private static func proxyPath(_ group: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return "/proxies/" + (group.addingPercentEncoding(withAllowedCharacters: allowed) ?? group)
    }

    /// DELETE /connections，关闭当前所有连接
    func closeAllConnections() async throws {
        try await send("DELETE", "/connections")
    }

    /// PUT /configs，以完整配置内容重新加载内核（仅 mihomo 支持）
    func reloadConfigs(payload: String) async throws {
        try await send("PUT", "/configs?force=true", body: ["path": "", "payload": payload], timeout: 30)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 5) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            struct Message: Decodable { var message: String }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? ""
            throw CoreControllerError.badStatus(http.statusCode, message)
        }
        return data
    }
}
