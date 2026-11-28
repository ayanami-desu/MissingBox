//
//  CoreUpdater.swift
//  MissingBox
//
//  从 GitHub Releases 下载并校验最新 alpha 内核，暂存后由 CoreManager 原子替换
//

import Darwin
import Foundation

nonisolated enum CoreUpdateError: LocalizedError {
    case releaseNotFound
    case extractFailed
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .releaseNotFound:
            String(localized: "Unable to find a compatible core release")
        case .extractFailed:
            String(localized: "Unable to extract the core archive")
        case .verificationFailed:
            String(localized: "Downloaded core failed verification")
        }
    }
}

nonisolated enum CoreUpdater {
    struct Release: Sendable {
        var version: String
        var downloadURL: URL
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        var tagName: String
        var prerelease: Bool
        var assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case prerelease
            case assets
        }
    }

    /// 查询对应内核最新的 arm64 alpha 预发布版本（与 CI 构建脚本渠道一致）
    static func latestRelease(for coreType: CoreType, proxyPorts: ProxyPorts?) async throws -> Release {
        switch coreType {
        case .mihomo:
            let url = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha")!
            let data = try await CoreController.fetchData(for: githubRequest(url), proxyPorts: proxyPorts)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let asset = release.assets.first(where: {
                $0.name.hasPrefix("mihomo-darwin-arm64-alpha-") && $0.name.hasSuffix(".gz")
            }) else {
                throw CoreUpdateError.releaseNotFound
            }
            let prefix = "mihomo-darwin-arm64-"
            let version = String(asset.name.dropFirst(prefix.count).dropLast(".gz".count))
            guard !version.isEmpty else { throw CoreUpdateError.releaseNotFound }
            return Release(version: version, downloadURL: asset.browserDownloadURL)

        case .singBox:
            let url = URL(string: "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20")!
            let data = try await CoreController.fetchData(for: githubRequest(url), proxyPorts: proxyPorts)
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            let selected = releases.first(where: { $0.prerelease && $0.tagName.contains("alpha") })
                ?? releases.first(where: { $0.prerelease })
                ?? releases.first
            guard let selected,
                  let asset = selected.assets.first(where: {
                      $0.name.hasPrefix("sing-box-") && $0.name.hasSuffix("-darwin-arm64.tar.gz")
                  }) else {
                throw CoreUpdateError.releaseNotFound
            }
            let version = selected.tagName.hasPrefix("v")
                ? String(selected.tagName.dropFirst())
                : selected.tagName
            guard !version.isEmpty else { throw CoreUpdateError.releaseNotFound }
            return Release(version: version, downloadURL: asset.browserDownloadURL)
        }
    }

    /// 下载、解压并校验新内核，返回 Core 目录下的隐藏暂存文件路径
    @concurrent
    static func downloadAndStage(_ release: Release, for coreType: CoreType, proxyPorts: ProxyPorts?) async throws -> URL {
        guard CoreDirectory.createIfNeeded(for: coreType) else {
            throw CoreError.launchFailed
        }

        var request = URLRequest(url: release.downloadURL, timeoutInterval: 180)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let archiveData = try await CoreController.fetchData(for: request, proxyPorts: proxyPorts)

        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory.appending(
            path: "MissingBox-core-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: stagingDir) }

        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let extractedURL = try extractBinary(from: archiveData, for: coreType, in: stagingDir)

        let stagedURL = CoreDirectory.url.appending(
            path: ".\(coreType.binaryName)-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )
        do {
            try fileManager.moveItem(at: extractedURL, to: stagedURL)
            removexattr(stagedURL.path, "com.apple.quarantine", 0)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedURL.path)
            adHocSign(stagedURL)
            guard verifyBinary(stagedURL, for: coreType) else {
                throw CoreUpdateError.verificationFailed
            }
            return stagedURL
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    /// 用 POSIX rename 原子替换内核二进制（目标可能是 root 所有的 setuid 文件，但 Core 目录归当前用户所有）；
    /// 原内核存在时先备份到同目录隐藏文件并返回路径，便于启动失败时回滚
    static func installStaged(_ stagedURL: URL, for coreType: CoreType) throws -> URL? {
        let fileManager = FileManager.default
        let destination = coreType.binaryURL
        var backupURL: URL?

        if fileManager.fileExists(atPath: destination.path) {
            let backup = CoreDirectory.url.appending(
                path: ".\(coreType.binaryName).backup-\(UUID().uuidString)",
                directoryHint: .notDirectory
            )
            if rename(destination.path, backup.path) != 0 {
                let err = errno
                try? fileManager.removeItem(at: stagedURL)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }
            backupURL = backup
        }

        if rename(stagedURL.path, destination.path) != 0 {
            let err = errno
            if let backupURL {
                _ = rename(backupURL.path, destination.path)
            }
            try? fileManager.removeItem(at: stagedURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        return backupURL
    }

    /// 新内核启动失败时，原子回滚旧内核二进制
    static func restoreBackup(_ backupURL: URL?, for coreType: CoreType) {
        guard let backupURL else { return }
        if rename(backupURL.path, coreType.binaryURL.path) != 0 {
            let err = errno
            NSLog("回滚内核 \(coreType.displayName) 失败：errno=\(err)")
        }
    }

    /// 清理备份的旧内核二进制
    static func removeBackup(_ backupURL: URL?) {
        guard let backupURL else { return }
        unlink(backupURL.path)
    }

    private static func githubRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MissingBox", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func extractBinary(from data: Data, for coreType: CoreType, in stagingDir: URL) throws -> URL {
        let fileManager = FileManager.default
        switch coreType {
        case .mihomo:
            let archiveURL = stagingDir.appending(path: "mihomo.gz", directoryHint: .notDirectory)
            let outputURL = stagingDir.appending(path: "mihomo", directoryHint: .notDirectory)
            do {
                try data.write(to: archiveURL, options: .atomic)
                fileManager.createFile(atPath: outputURL.path, contents: nil)
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                defer { try? outputHandle.close() }

                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/gzip")
                process.arguments = ["-dc", archiveURL.path]
                process.standardOutput = outputHandle
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw CoreUpdateError.extractFailed
                }
                return outputURL
            } catch let error as CoreUpdateError {
                throw error
            } catch {
                NSLog("解压 mihomo 失败：\(error)")
                throw CoreUpdateError.extractFailed
            }

        case .singBox:
            let archiveURL = stagingDir.appending(path: "sing-box.tar.gz", directoryHint: .notDirectory)
            let unpackedDir = stagingDir.appending(path: "unpacked", directoryHint: .isDirectory)
            do {
                try fileManager.createDirectory(at: unpackedDir, withIntermediateDirectories: true)
                try data.write(to: archiveURL, options: .atomic)

                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/tar")
                process.arguments = ["-xzf", archiveURL.path, "-C", unpackedDir.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw CoreUpdateError.extractFailed
                }

                if let enumerator = fileManager.enumerator(
                    at: unpackedDir,
                    includingPropertiesForKeys: [.isRegularFileKey]
                ) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.lastPathComponent == "sing-box",
                           (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                            return fileURL
                        }
                    }
                }
                throw CoreUpdateError.extractFailed
            } catch let error as CoreUpdateError {
                throw error
            } catch {
                NSLog("解压 sing-box 失败：\(error)")
                throw CoreUpdateError.extractFailed
            }
        }
    }

    private static func adHocSign(_ url: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                NSLog("内核临时签名返回状态 \(process.terminationStatus)")
            }
        } catch {
            NSLog("内核临时签名失败：\(error)")
        }
    }

    private static func verifyBinary(_ url: URL, for coreType: CoreType) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = url
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
            NSLog("校验新内核 \(coreType.displayName) 失败：\(error)")
            return false
        }
        defer { CoreHelperProcesses.unregister(pid) }

        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
