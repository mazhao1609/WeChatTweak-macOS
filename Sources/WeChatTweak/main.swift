//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import Dispatch
import ArgumentParser

// MARK: Versions
extension Tweak {
    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all supported WeChat versions")

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            print("------ Current version ------")
            print(try await Command.version(app: options.app) ?? "unknown")
            print("------ Supported versions ------")
            try await Config.load(url: options.config).forEach({ print($0.version) })
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Patch
extension Tweak {
    struct Patch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

        @OptionGroup
        var options: Tweak.Options

        @Flag(help: "只检查当前核心库和注入位置，不修改微信")
        var dryRun = false

        @Option(help: "运行时动态库路径")
        var runtimeLibrary: String = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent(Command.libraryName).path

        @Option(help: "系统撤回通知：all 或 off；聊天内提示始终保留")
        var notifications = "all"

        mutating func run() async throws {
            print("------ Version ------")
            let version = try await Command.version(app: options.app)
            print("WeChat version: \(version ?? "unknown")")

            print("------ Config ------")
            guard let config = (try await Config.load(url: options.config)).first(where: { $0.version == version }) else {
                throw Error.unsupportedVersion
            }
            guard ["all", "off"].contains(notifications) else { throw ValidationError("notifications 仅支持 all 或 off") }
            print("Matched config: \(config.version)")

            print("------ Patch ------")
            try Command.patch(
                app: options.app,
                config: config,
                runtimeLibrary: URL(fileURLWithPath: runtimeLibrary),
                dryRun: dryRun,
                notifications: notifications
            )
            print("Done!")

            Darwin.exit(EXIT_SUCCESS)
        }
    }

}

extension Tweak {
    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "恢复安装前备份的微信")
        @OptionGroup var options: Tweak.Options
        mutating func run() async throws {
            try Command.restore(app: options.app)
            // 与安装命令一致，完成后退出主队列事件循环。
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Tweak
struct Tweak: AsyncParsableCommand {
    enum Error: LocalizedError {
        case invalidApp
        case invalidConfig
        case invalidVersion
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Invalid app path"
            case .invalidConfig:
                return "Invalid patch config"
            case .invalidVersion:
                return "Invalid app version"
            case .unsupportedVersion:
                return "Unsupported WeChat version"
            }
        }
    }

    struct Options: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Path of WeChat.app",
            transform: {
                guard FileManager.default.fileExists(atPath: $0) else {
                    throw Error.invalidApp
                }
                return URL(fileURLWithPath: $0)
            }
        )
        var app: URL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)

        @Option(
            name: .shortAndLong,
            help: "Local path or Remote URL of config.json",
            transform: {
                if FileManager.default.fileExists(atPath: $0) {
                    return URL(fileURLWithPath: $0)
                } else {
                    guard let url = URL(string: $0) else {
                        throw Error.invalidConfig
                    }
                    return url
                }
            }
        )
        var config: URL = Bundle.module.url(forResource: "config", withExtension: "json")!
    }

    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Versions.self,
            Patch.self,
            Restore.self
        ]
    )

    mutating func run() async throws {
        print(Tweak.helpMessage())
        Darwin.exit(EXIT_SUCCESS)
    }
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()
