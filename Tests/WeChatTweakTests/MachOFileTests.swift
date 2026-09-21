// Created by Ma
import XCTest
import MachO
@testable import WeChatTweak

final class MachOFileTests: XCTestCase {
    private func fixture() -> Data {
        var bytes = Data(repeating: 0, count: 4096)
        func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.replaceSubrange(offset..<offset + $0.count, with: $0) }
        }
        put(UInt32(MH_MAGIC_64), 0)
        put(UInt32(CPU_TYPE_ARM64), 4)
        put(UInt32(1), 16)
        put(UInt32(152), 20)
        put(UInt32(LC_SEGMENT_64), 32)
        put(UInt32(152), 36)
        put(UInt64(0x100000000), 56)
        put(UInt64(8192), 64)
        put(UInt64(4096), 80)
        put(UInt32(1), 96)
        put(UInt32(1024), 152)
        return bytes
    }

    func testInjectIsIdempotentAndKeepsPayload() throws {
        let original = fixture()
        var file = try MachOFile(data: original)
        try file.inject(library: Command.loadPath, cpu: UInt32(CPU_TYPE_ARM64))
        XCTAssertEqual(try file.uint32(16), 2)
        XCTAssertEqual(file.data[1024...], original[1024...])
        let patched = file.data
        try file.inject(library: Command.loadPath, cpu: UInt32(CPU_TYPE_ARM64))
        XCTAssertEqual(file.data, patched)
    }

    func testMappedFileIsNotWrittenDuringPreflight() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = fixture()
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var file = try MachOFile(url: url)
        try file.inject(library: Command.loadPath, cpu: UInt32(CPU_TYPE_ARM64))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRejectsTruncatedCommandsAndUnknownArchitecture() throws {
        XCTAssertThrowsError(try MachOFile(data: Data([0, 1, 2])))
        var bytes = fixture()
        bytes.replaceSubrange(36..<40, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try MachOFile(data: bytes))
        XCTAssertThrowsError(try MachOFile(data: fixture()).slice(cpu: UInt32(CPU_TYPE_X86_64)))
    }

    func testRejectsBSSAndPatchCrossingFileEnd() throws {
        let file = try MachOFile(data: fixture())
        let slice = try file.slice(cpu: UInt32(CPU_TYPE_ARM64))
        XCTAssertEqual(try file.fileOffset(va: 0x100000100, count: 16, in: slice), 256)
        XCTAssertThrowsError(try file.fileOffset(va: 0x100001000, count: 4, in: slice))
        XCTAssertThrowsError(try file.fileOffset(va: 0x100000ffe, count: 4, in: slice))
    }

    func testRejectsNonzeroHeaderPaddingWithoutMutation() throws {
        var bytes = fixture()
        bytes[184] = 1
        var file = try MachOFile(data: bytes)
        XCTAssertThrowsError(try file.inject(library: Command.loadPath, cpu: UInt32(CPU_TYPE_ARM64)))
        XCTAssertEqual(file.data, bytes)
    }
}
