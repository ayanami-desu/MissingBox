//
//  ConfigValidator.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation

/// 校验时依次检查的各层配置
nonisolated enum ConfigLayer {
    case profile
    case profileOverride
    case globalOverride

    var title: String {
        switch self {
        case .profile: String(localized: "Profile")
        case .profileOverride: String(localized: "Profile with profile override applied")
        case .globalOverride: String(localized: "Profile with global override applied")
        }
    }
}

nonisolated enum ConfigValidationError: LocalizedError {
    case failed(ConfigLayer, String?)

    var errorDescription: String? {
        switch self {
        case .failed(let layer, let message): String(localized: "Validation failed (\(layer.title)): \(message ?? String(localized: "Unknown error"))")
        }
    }
}

/// 由对应内核完整解析配置（mihomo -t / sing-box check），与实际加载时的检查一致；
/// 覆写为空的层与上一层相同，不再重复检查
enum ConfigValidator {
    /// 导入、编辑、更新配置时：检查配置本身，以及依次应用配置覆写、全局覆写后的配置
    static func validate(profile: Data, profileOverride: String, coreType: CoreType) async throws {
        try await validate(profile: profile, profileOverride: profileOverride, coreType: coreType, checksProfile: true)
    }

    /// 保存配置覆写时：检查应用配置覆写后的配置，以及再应用全局覆写后的配置
    static func validate(profileOverride: String, of profile: Data, coreType: CoreType) async throws {
        try await validate(profile: profile, profileOverride: profileOverride, coreType: coreType, checksProfile: false)
    }

    private static func validate(profile: Data, profileOverride: String, coreType: CoreType, checksProfile: Bool) async throws {
        let binary = coreType.binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw CoreError.binaryNotFound(coreType)
        }
        guard CoreDirectory.createIfNeeded(for: coreType) else { throw CoreError.launchFailed }
        try await check(
            coreType: coreType,
            profile: profile,
            profileOverride: profileOverride,
            globalOverride: ConfigOverride.global(coreType).load(),
            checksProfile: checksProfile,
            binary: binary,
            home: coreType.homeURL
        )
    }

    @concurrent
    private nonisolated static func check(
        coreType: CoreType,
        profile: Data,
        profileOverride: String,
        globalOverride: String,
        checksProfile: Bool,
        binary: URL,
        home: URL
    ) async throws {
        if checksProfile {
            try test(profile, coreType: coreType, layer: .profile, binary: binary, home: home)
        }

        switch coreType {
        case .mihomo:
            var root = try CoreConfig.mapping(from: String(decoding: profile, as: UTF8.self))

            let profileOverride = try ConfigOverride.parse(profileOverride)
            if !checksProfile || !profileOverride.isEmpty {
                ConfigOverride.merge(profileOverride, into: &root)
                try test(Data(CoreConfig.serialize(root).utf8), coreType: .mihomo, layer: .profileOverride, binary: binary, home: home)
            }

            let globalOverride = try ConfigOverride.parse(globalOverride)
            if !globalOverride.isEmpty {
                ConfigOverride.merge(globalOverride, into: &root)
                try test(Data(CoreConfig.serialize(root).utf8), coreType: .mihomo, layer: .globalOverride, binary: binary, home: home)
            }

        case .singBox:
            var root = try SingBoxJSON.parseObject(String(decoding: profile, as: UTF8.self))

            let profileOverride = try SingBoxJSON.parseObject(profileOverride, allowEmpty: true)
            if !checksProfile || !profileOverride.isEmpty {
                SingBoxJSON.merge(profileOverride, into: &root)
                try test(Data(SingBoxJSON.serialize(root).utf8), coreType: .singBox, layer: .profileOverride, binary: binary, home: home)
            }

            let globalOverride = try SingBoxJSON.parseObject(globalOverride, allowEmpty: true)
            if !globalOverride.isEmpty {
                SingBoxJSON.merge(globalOverride, into: &root)
                try test(Data(SingBoxJSON.serialize(root).utf8), coreType: .singBox, layer: .globalOverride, binary: binary, home: home)
            }
        }
    }

    /// 与启动内核一致：mihomo 经 CLASH_CONFIG_STRING 传入，sing-box 经 stdin 传入
    private nonisolated static func test(_ data: Data, coreType: CoreType, layer: ConfigLayer, binary: URL, home: URL) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = binary
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var inputPipe: Pipe?
        switch coreType {
        case .mihomo:
            var environment = ProcessInfo.processInfo.environment
            environment["CLASH_CONFIG_STRING"] = data.base64EncodedString()
            process.arguments = ["-d", home.path, "-t"]
            process.environment = environment
        case .singBox:
            let pipe = Pipe()
            process.arguments = ["check", "-D", home.path, "-c", "stdin", "--disable-color"]
            process.standardInput = pipe
            inputPipe = pipe
        }

        let pid: pid_t
        do {
            pid = try CoreHelperProcesses.run(process)
        } catch {
            NSLog("运行内核 \(coreType.displayName) 失败：\(error)")
            throw CoreError.launchFailed
        }
        defer { CoreHelperProcesses.unregister(pid) }

        if let inputPipe {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
            try? inputPipe.fileHandleForWriting.close()
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConfigValidationError.failed(layer, CoreLog.lastError(in: String(decoding: output, as: UTF8.self), for: coreType))
        }
    }
}
