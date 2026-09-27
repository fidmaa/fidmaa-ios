import Foundation
import Testing
@testable import FidmaaCore

@Test func invalidDepthIsBlack() {
    for v: Float in [.nan, 0, -1, .infinity] {
        let c = DepthColormap.color(depth: v)
        #expect(c.r == 0 && c.g == 0 && c.b == 0)
    }
}

@Test func nearIsRedFarIsBlue() {
    let near = DepthColormap.color(depth: 0.25)
    let far = DepthColormap.color(depth: 1.1)
    #expect(near.r > near.b)
    #expect(far.b > far.r)
}

@Test func outOfRangeClampsToEnds() {
    let a = DepthColormap.color(depth: 0.05)
    let b = DepthColormap.color(depth: DepthColormap.nearMeters)
    #expect(a.r == b.r && a.g == b.g && a.b == b.b)
    let c = DepthColormap.color(depth: 9)
    let d = DepthColormap.color(depth: DepthColormap.farMeters)
    #expect(c.r == d.r && c.g == d.g && c.b == d.b)
}

@Test func rgbaLayout() {
    let bytes = DepthColormap.rgba([0.3, .nan])
    #expect(bytes.count == 8)
    #expect(bytes[3] == 255 && bytes[7] == 255)
    #expect(bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0)
}

@Test func captureFoldersNewestFirstWithPhotoOnly() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        do { try fm.removeItem(at: base) } catch { Issue.record(error) }
    }
    for name in ["20260927-201819", "20260927-203837", "20260927-202335", "empty-folder"] {
        let dir = base.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if name != "empty-folder" { try Data([1]).write(to: dir.appendingPathComponent("photo.heic")) }
    }
    try Data([1]).write(to: base.appendingPathComponent("stray.txt"))
    let names = try CaptureLibrary.captureFolders(in: base).map(\.lastPathComponent)
    #expect(names == ["20260927-203837", "20260927-202335", "20260927-201819"])
}

@Test func captureDisplayName() {
    #expect(CaptureLibrary.displayName(forFolder: "20260927-203837") == "27.09 20:38:37")
    #expect(CaptureLibrary.displayName(forFolder: "20260927-203837-2") == "27.09 20:38:37 (2)")
    #expect(CaptureLibrary.displayName(forFolder: "other") == "other")
}
