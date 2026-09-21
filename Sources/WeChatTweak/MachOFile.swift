// Created by Ma
import Foundation
import MachO

struct MachOFile {
    struct Slice {
        let cpu: UInt32
        let offset: Int
        let size: Int
    }
    var data: Data
    let slices: [Slice]

    init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    init(data: Data) throws {
        self.data = data
        func read(_ offset: Int, big: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw TweakFailure("Mach-O 文件截断。") }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return big ? value.bigEndian : value.littleEndian
        }
        let magic = try read(0, big: true)
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            let big = magic == FAT_MAGIC
            let count = Int(try read(4, big: big))
            guard count > 0, count <= (data.count - 8) / 20 else { throw TweakFailure("FAT 架构表无效。") }
            slices = try (0..<count).map { index in
                let offset = 8 + index * 20
                let start = Int(try read(offset + 8, big: big))
                let size = Int(try read(offset + 12, big: big))
                guard start >= 8 + count * 20, size >= 32, start <= data.count - size else {
                    throw TweakFailure("FAT 切片越界。")
                }
                return Slice(cpu: try read(offset, big: big), offset: start, size: size)
            }
        } else {
            slices = [Slice(cpu: try read(4), offset: 0, size: data.count)]
        }
        for slice in slices {
            guard try read(slice.offset) == MH_MAGIC_64,
                  try read(slice.offset + 4) == slice.cpu else { throw TweakFailure("仅支持小端 64 位 Mach-O。") }
            _ = try commands(in: slice)
        }
    }

    func uint32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw TweakFailure("Mach-O 读取越界。") }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
    func uint64(_ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else { throw TweakFailure("Mach-O 读取越界。") }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }
    func slice(cpu: UInt32) throws -> Slice {
        guard let slice = slices.first(where: { $0.cpu == cpu }) else { throw TweakFailure("缺少所需架构。") }
        return slice
    }
    func commands(in slice: Slice) throws -> [(kind: UInt32, offset: Int, size: Int)] {
        let count = Int(try uint32(slice.offset + 16))
        let size = Int(try uint32(slice.offset + 20))
        guard size <= slice.size - 32, count <= size / 8 else { throw TweakFailure("加载命令无效。") }
        let end = slice.offset + 32 + size
        var cursor = slice.offset + 32
        var result: [(UInt32, Int, Int)] = []
        for _ in 0..<count {
            guard cursor <= end - 8 else { throw TweakFailure("加载命令截断。") }
            let kind = try uint32(cursor)
            let length = Int(try uint32(cursor + 4))
            guard length >= 8, length % 8 == 0, length <= end - cursor else { throw TweakFailure("加载命令长度无效。") }
            result.append((kind, cursor, length))
            cursor += length
        }
        guard cursor == end else { throw TweakFailure("加载命令长度不一致。") }
        return result
    }
    func uuid(in slice: Slice) throws -> String? {
        for command in try commands(in: slice) where command.kind == LC_UUID {
            guard command.size == 24 else { throw TweakFailure("UUID 命令无效。") }
            let b = Array(data[command.offset + 8..<command.offset + 24])
            return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
        }
        return nil
    }
    func fileOffset(va: UInt64, count: Int, in slice: Slice) throws -> Int {
        guard count >= 0 else { throw TweakFailure("补丁长度无效。") }
        for command in try commands(in: slice) where command.kind == LC_SEGMENT_64 {
            guard command.size >= 72 else { throw TweakFailure("段命令截断。") }
            let start = try uint64(command.offset + 24)
            let offset = try uint64(command.offset + 40)
            let size = try uint64(command.offset + 48)
            // 使用文件大小而非虚拟内存大小，禁止写进 BSS 或下一个切片。
            guard va >= start, va - start <= size, UInt64(count) <= size - (va - start),
                  offset <= UInt64(slice.size), size <= UInt64(slice.size) - offset else { continue }
            return slice.offset + Int(offset + va - start)
        }
        throw TweakFailure("地址 \(String(va, radix: 16)) 不在文件段内。")
    }
    mutating func inject(library: String, cpu: UInt32) throws {
        let slice = try slice(cpu: cpu)
        let commands = try commands(in: slice)
        var firstSection = slice.size
        for command in commands {
            if command.kind == LC_LOAD_DYLIB {
                guard command.size >= 24 else { throw TweakFailure("动态库命令截断。") }
                let nameOffset = Int(try uint32(command.offset + 8))
                guard nameOffset >= 24, nameOffset < command.size else { throw TweakFailure("动态库名称越界。") }
                let name = data[command.offset + nameOffset..<command.offset + command.size].prefix(while: { $0 != 0 })
                if String(decoding: name, as: UTF8.self) == library { return }
            }
            if command.kind == LC_SEGMENT_64 {
                guard command.size >= 72 else { throw TweakFailure("段命令截断。") }
                let count = Int(try uint32(command.offset + 64))
                guard count <= (command.size - 72) / 80 else { throw TweakFailure("节表截断。") }
                for index in 0..<count {
                    let offset = Int(try uint32(command.offset + 72 + index * 80 + 48))
                    if offset > 0 { firstSection = min(firstSection, offset) }
                }
            }
        }
        let oldSize = Int(try uint32(slice.offset + 20))
        let start = slice.offset + 32 + oldSize
        let name = Data(library.utf8) + Data([0])
        let size = (24 + name.count + 7) & ~7
        guard start + size <= slice.offset + firstSection,
              data[start..<start + size].allSatisfy({ $0 == 0 }) else { throw TweakFailure("主程序没有足够的加载命令空间。") }
        // 映射数据可能是只读内存，写入前显式复制，检查模式也不能修改文件映射。
        data = data.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        var command = Data(repeating: 0, count: size)
        func store(_ value: UInt32, in bytes: inout Data, at offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        store(UInt32(LC_LOAD_DYLIB), in: &command, at: 0)
        store(UInt32(size), in: &command, at: 4)
        store(24, in: &command, at: 8)
        command.replaceSubrange(24..<24 + name.count, with: name)
        data.replaceSubrange(start..<start + size, with: command)
        store(UInt32(commands.count + 1), in: &data, at: slice.offset + 16)
        store(UInt32(oldSize + size), in: &data, at: slice.offset + 20)
    }
}
