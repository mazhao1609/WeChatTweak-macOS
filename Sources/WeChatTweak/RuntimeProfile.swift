// Created by Ma
import Foundation

struct RuntimeProfile: Codable {
    struct Function: Codable {
        let addr: String
        let expected: String
    }
    let version: String
    let image: String
    let uuid: String
    let functions: [String: Function]

    func validate(app: URL) throws {
        #if !arch(arm64)
        throw TweakFailure("此版本仅适配 Apple Silicon 原生运行。")
        #else
        guard image == "Contents/Resources/wechat.dylib" else { throw TweakFailure("核心库路径无效。") }
        let required = Set(["handleRevoke", "lookupMessage", "messageInit", "messageDestroy", "setMessageType",
                            "refreshMessage", "addLocalMessage", "notifyAdded", "accountService"])
        guard version == "270100", Set(functions.keys) == required else { throw TweakFailure("运行时适配配置不完整。") }
        let file = try MachOFile(url: app.appendingPathComponent(image))
        let slice = try file.slice(cpu: Config.Arch.arm64.cpu)
        guard try file.uuid(in: slice) == uuid.uppercased() else { throw TweakFailure("核心库 UUID 不匹配，拒绝安装。") }
        for (name, function) in functions {
            guard let address = UInt64(function.addr, radix: 16),
                  let expected = Data(hex: function.expected), expected.count >= 16 else {
                throw TweakFailure("\(name) 的函数校验配置无效。")
            }
            let offset = try file.fileOffset(va: address, count: expected.count, in: slice)
            guard file.data.subdata(in: offset..<offset + expected.count) == expected else {
                throw TweakFailure("\(name) 原始指令不匹配，拒绝安装。")
            }
        }
        #endif
    }
}

struct TweakFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
