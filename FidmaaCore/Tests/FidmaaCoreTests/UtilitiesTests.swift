import Foundation
import Testing
@testable import FidmaaCore

@Test func littleEndianDataDropsRowPadding() {
    // 2x2 image, row stride 3 (one padding element per row)
    let values: [Float] = [1, 2, 99, 3, 4, 99]
    let data = values.withUnsafeBufferPointer {
        DepthRaw.littleEndianData($0, width: 2, height: 2, rowStride: 3)
    }
    #expect(data.count == 16)
    let decoded = (0..<4).map { i in
        Float(bitPattern: UInt32(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
        }))
    }
    #expect(decoded == [1, 2, 3, 4])
}

@Test func floatsFromNativeData() {
    let source: [Float] = [0.5, -1.25, 3]
    let data = source.withUnsafeBytes { Data($0) }
    #expect(DepthRaw.floats(fromNativeData: data) == source)
    #expect(DepthRaw.floats(fromNativeData: Data([1, 2, 3])) == [])
}

@Test func fourCC() {
    #expect(FourCC.string(0x6664_6570) == "fdep")
    #expect(FourCC.string(0x6864_6973) == "hdis")
}

@Test func exifMirroring() {
    #expect([1, 2, 3, 4, 5, 6, 7, 8].filter(ExifOrientation.isMirrored) == [2, 4, 5, 7])
}

@Test func rowMajorTransposesColumns() {
    #expect(Matrix.rowMajor(columns: [[1, 2, 3], [4, 5, 6], [7, 8, 9]]) == [[1, 4, 7], [2, 5, 8], [3, 6, 9]])
    // 4 columns x 3 rows (extrinsic) -> 3 rows of 4
    #expect(Matrix.rowMajor(columns: [[1, 0, 0], [0, 1, 0], [0, 0, 1], [5, 6, 7]])
            == [[1, 0, 0, 5], [0, 1, 0, 6], [0, 0, 1, 7]])
    #expect(Matrix.rowMajor(columns: []) == [])
}

@Test func folderNameFormat() {
    let utc = TimeZone(identifier: "UTC")!
    #expect(ExportNaming.folderName(for: Date(timeIntervalSince1970: 0), timeZone: utc) == "19700101-000000")
}

@Test func uniqueFoldersForSameSecond() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        do { try FileManager.default.removeItem(at: base) } catch { Issue.record(error) }
    }
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 0)
    let first = try ExportNaming.createUniqueFolder(in: base, date: date, timeZone: utc)
    let second = try ExportNaming.createUniqueFolder(in: base, date: date, timeZone: utc)
    #expect(first.lastPathComponent == "19700101-000000")
    #expect(second.lastPathComponent == "19700101-000000-2")
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: second.path, isDirectory: &isDir) && isDir.boolValue)
}
