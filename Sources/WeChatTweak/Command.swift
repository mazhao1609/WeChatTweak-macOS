// Created by Ma
import AppKit
import Foundation

struct Command {
    static let libraryName = "libWeChatTweak.dylib"
    static let loadPath = "@executable_path/../Frameworks/\(libraryName)"

    static func version(app: URL) async throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "com.tencent.xinWeChat" else { throw TweakFailure("所选应用不是微信。") }
        return info?["CFBundleVersion"] as? String
    }

    static func ensureStopped(app: URL) throws {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }) { throw TweakFailure("请先退出微信，再安装或恢复。检查可使用 --dry-run。") }
    }

    static func backupURL(app: URL) -> URL { app.appendingPathExtension("wechattweak-backup") }

    static func patch(app: URL, config: Config, runtimeLibrary: URL, dryRun: Bool, notifications: String) throws {
        let executable = app.appendingPathComponent("Contents/MacOS/WeChat")
        if let profile = config.runtime {
            guard profile.version == config.version else { throw TweakFailure("运行时版本配置不一致。") }
            try profile.validate(app: app)
            var binary = try MachOFile(url: executable)
            try binary.inject(library: loadPath, cpu: Config.Arch.arm64.cpu)
            print("核心库 UUID、函数指令和注入空间校验通过（arm64）。")
            if dryRun { return }
            guard FileManager.default.fileExists(atPath: runtimeLibrary.path) else {
                throw TweakFailure("未找到 \(runtimeLibrary.path)，请先执行 make build。")
            }
            _ = try MachOFile(url: runtimeLibrary).slice(cpu: Config.Arch.arm64.cpu)
        } else if dryRun {
            throw TweakFailure("--dry-run 目前仅用于含运行时配置的新版本。")
        }
        try ensureStopped(app: app)
        let fm = FileManager.default
        let backup = backupURL(app: app)
        guard !fm.fileExists(atPath: backup.path) else { throw TweakFailure("已有备份 \(backup.path)，请先 restore 后再安装。") }
        let staging = app.deletingLastPathComponent().appendingPathComponent(".wechattweak-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stagedApp = staging.appendingPathComponent(app.lastPathComponent)
        // 在副本上完成修改和签名，原应用只在所有步骤成功后替换。
        try execute("/usr/bin/ditto", [app.path, stagedApp.path])
        let stagedBinary = stagedApp.appendingPathComponent("Contents/MacOS/WeChat")
        if let profile = config.runtime {
            let frameworks = stagedApp.appendingPathComponent("Contents/Frameworks")
            let resources = stagedApp.appendingPathComponent("Contents/Resources")
            let library = frameworks.appendingPathComponent(libraryName)
            if fm.fileExists(atPath: library.path) { try fm.removeItem(at: library) }
            try fm.copyItem(at: runtimeLibrary, to: library)
            // 配置属于资源；放入 Frameworks 会被签名工具视为嵌套代码。
            try JSONEncoder().encode(profile).write(to: resources.appendingPathComponent("WeChatTweakProfile.json"))
            try JSONSerialization.data(withJSONObject: ["notifications": notifications]).write(
                to: resources.appendingPathComponent("WeChatTweakSettings.json"))
            var binary = try MachOFile(url: stagedBinary)
            try binary.inject(library: loadPath, cpu: Config.Arch.arm64.cpu)
            try binary.data.write(to: stagedBinary)
            try execute("/usr/bin/codesign", ["--force", "--sign", "-", library.path])
        } else {
            try Patcher.patch(binary: stagedBinary, config: config)
        }
        // 保留微信原有权限；仅取消依赖原厂签名的库验证。
        let entitlementData = try output("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path])
        var entitlements = try PropertyListSerialization.propertyList(from: entitlementData, format: nil) as? [String: Any] ?? [:]
        entitlements["com.apple.security.cs.disable-library-validation"] = true
        let entitlementURL = staging.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: entitlementURL)
        // 仅重签主应用；--deep 会把主应用权限覆盖到子组件，破坏小程序进程的沙盒继承。
        // 未修改的辅助应用、扩展和框架必须保留各自的原厂签名及权限；验证仍递归执行。
        try execute("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlementURL.path, stagedApp.path])
        try execute("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
        try ensureStopped(app: app)
        try fm.moveItem(at: app, to: backup)
        do { try fm.moveItem(at: stagedApp, to: app) }
        catch {
            try fm.moveItem(at: backup, to: app)
            throw error
        }
        print("安装完成；原版备份：\(backup.path)")
    }

    static func restore(app: URL) throws {
        try ensureStopped(app: app)
        let fm = FileManager.default
        let backup = backupURL(app: app)
        guard fm.fileExists(atPath: backup.path) else { throw TweakFailure("未找到原版备份。") }
        let removed = app.appendingPathExtension("wechattweak-removed-\(UUID().uuidString)")
        try fm.moveItem(at: app, to: removed)
        do { try fm.moveItem(at: backup, to: app) }
        catch {
            try fm.moveItem(at: removed, to: app)
            throw error
        }
        try fm.removeItem(at: removed)
        print("已恢复安装前的微信。")
    }

    @discardableResult
    static func execute(_ executable: String, _ arguments: [String]) throws -> Data {
        try output(executable, arguments)
    }

    static func output(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TweakFailure("\(executable) 失败（\(process.terminationStatus)）。") }
        return output
    }
}
