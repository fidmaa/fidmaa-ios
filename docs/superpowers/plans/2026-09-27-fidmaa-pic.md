# fidmaa-pic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aplikacja iOS robiąca przednim aparatem TrueDepth zdjęcie portretowe z głębią absolute (metry) i maskami (portrait, hair, skin, teeth, glasses), zapisywane do Zdjęć i do folderu w Plikach.

**Architecture:** Czysta logika (mediana głębi, JSON metadanych, pakowanie float32, nazwy folderów) w lokalnym pakiecie Swift `FidmaaCore`, testowanym na macOS (`swift test`) — w środowisku nie ma runtime'u symulatora iOS. Aplikacja SwiftUI (`FidmaaPic`) zależy od pakietu i zawiera kod AVFoundation/ImageIO/Photos. Projekt Xcode pisany ręcznie (objectVersion 77, folder synchronizowany + `XCLocalSwiftPackageReference`).

**Tech Stack:** Swift, SwiftUI, AVFoundation, ImageIO, Photos, Swift Testing, Xcode 26.6, iOS 26.

**Spec:** `docs/superpowers/specs/2026-09-27-fidmaa-pic-design.md`

## Global Constraints

- Deployment target: iOS 26.0, tylko iPhone (`TARGETED_DEVICE_FAMILY = 1`), tylko pion.
- Kamera: `.builtInTrueDepthCamera`, `.front`.
- Głębia zapisywana jako `kCVPixelFormatType_DepthFloat32`, metry; `isDepthDataFiltered = false` dla zdjęcia.
- Progi odległości: `< 0.25 m` → „Odsuń się”, `> 0.70 m` → „Przybliż się”; środkowy obszar 30% × 30%.
- Pliki w `Documents/YYYYMMDD-HHmmss/`: `photo.heic`, `depth.tiff`, `depth.f32`, `portrait.png`, `hair.png`, `skin.png`, `teeth.png`, `glasses.png`, `calibration.json`.
- Macierze w JSON row-major. Brakujące wartości w JSON jako `null` (klucz obecny).
- Żadnych pustych `catch` — każdy błąd logowany przez `Logger` i/lub pokazany w UI.
- Bez zewnętrznych zależności.

**Odstępstwa od spec (świadome):** podgląd odległości używa samego `AVCaptureDepthDataOutput` (bez `AVCaptureVideoDataOutput` + synchronizatora — podgląd obrazu robi `AVCaptureVideoPreviewLayer`); testy jednostkowe żyją w `FidmaaCore/Tests` zamiast `FidmaaPicTests`.

## Review Focus

1. Bufor głębi z paddingiem wierszy (`bytesPerRow > width*4`) — mediana i `depth.f32` muszą pomijać padding. Testy: Task 1 (`rowStride`), Task 2 (`littleEndianData` z paddingiem).
2. Niefiltrowana głębia z dziurami (NaN, 0, ujemne, inf) — ignorowane w medianie; same dziury → „Brak danych głębi”. Test: Task 1.
3. Dwa zdjęcia w tej samej sekundzie — dwa różne foldery (`-2`). Test: Task 2.
4. Brak twarzy w kadrze → brak masek; JSON ma `null`, pozostałe pliki zapisane. Test: Task 3 (null w JSON), reszta ręcznie.
5. NaN w liczbach JSON nie może wywalić zapisu metadanych. Test: Task 3.

---

## File Structure

```
.gitignore
README.md                                  – obsługa, Python, checklista ręczna
FidmaaPic-Info.plist                       – klucze niedostępne przez INFOPLIST_KEY_*
FidmaaPic.xcodeproj/project.pbxproj
FidmaaCore/Package.swift
FidmaaCore/Sources/FidmaaCore/DistanceEstimator.swift
FidmaaCore/Sources/FidmaaCore/DepthRaw.swift        – float32 → Data, Data → [Float]
FidmaaCore/Sources/FidmaaCore/Formatting.swift      – FourCC, ExifOrientation, Matrix
FidmaaCore/Sources/FidmaaCore/ExportNaming.swift
FidmaaCore/Sources/FidmaaCore/CaptureMetadata.swift
FidmaaCore/Tests/FidmaaCoreTests/DistanceEstimatorTests.swift
FidmaaCore/Tests/FidmaaCoreTests/UtilitiesTests.swift
FidmaaCore/Tests/FidmaaCoreTests/CaptureMetadataTests.swift
FidmaaPic/FidmaaPicApp.swift
FidmaaPic/ContentView.swift
FidmaaPic/CameraPreviewView.swift
FidmaaPic/CameraController.swift
FidmaaPic/PhotoCaptureProcessor.swift
FidmaaPic/CaptureExporter.swift
FidmaaPic/ImageFileWriter.swift
FidmaaPic/PixelBufferAccess.swift
FidmaaPic/PhotoLibrarySaver.swift
FidmaaPic/DeviceInfo.swift
```

---

### Task 1: Pakiet FidmaaCore + DistanceEstimator

**Files:**
- Create: `FidmaaCore/Package.swift`, `FidmaaCore/Sources/FidmaaCore/DistanceEstimator.swift`
- Test: `FidmaaCore/Tests/FidmaaCoreTests/DistanceEstimatorTests.swift`

**Interfaces:**
- Produces: `DistanceStatus` (`.noData`, `.tooClose(meters:)`, `.tooFar(meters:)`, `.ok(meters:)`, `var message: String`), `DistanceEstimator.medianCenterDepth(_: UnsafeBufferPointer<Float>, width: Int, height: Int, rowStride: Int) -> Float?`, `DistanceEstimator.status(forMedian: Float?) -> DistanceStatus`.

- [ ] **Step 1: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FidmaaCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "FidmaaCore", targets: ["FidmaaCore"]),
    ],
    targets: [
        .target(name: "FidmaaCore"),
        .testTarget(name: "FidmaaCoreTests", dependencies: ["FidmaaCore"]),
    ]
)
```

- [ ] **Step 2: Failing tests**

```swift
import Testing
@testable import FidmaaCore

/// Builds a width×height grid (with optional row padding) filled with `fill`,
/// then applies `set` for explicit (x, y) values.
private func grid(width: Int, height: Int, rowStride: Int? = nil, fill: Float,
                  padding: Float = 99, set: [(Int, Int, Float)] = []) -> [Float] {
    let stride = rowStride ?? width
    var values = [Float](repeating: padding, count: stride * height)
    for y in 0..<height { for x in 0..<width { values[y * stride + x] = fill } }
    for (x, y, v) in set { values[y * stride + x] = v }
    return values
}

private func median(_ values: [Float], width: Int, height: Int, rowStride: Int? = nil) -> Float? {
    values.withUnsafeBufferPointer {
        DistanceEstimator.medianCenterDepth($0, width: width, height: height, rowStride: rowStride ?? width)
    }
}

@Test func uniformDepthGivesThatDepth() {
    #expect(median(grid(width: 10, height: 10, fill: 0.4), width: 10, height: 10) == 0.4)
}

@Test func onlyCenterRegionCounts() {
    // 10x10, center 30% = 3x3 at x,y in 3...5
    var set: [(Int, Int, Float)] = []
    for y in 3...5 { for x in 3...5 { set.append((x, y, 0.5)) } }
    #expect(median(grid(width: 10, height: 10, fill: 9, set: set), width: 10, height: 10) == 0.5)
}

@Test func invalidValuesAreIgnored() {
    let center: [Float] = [.nan, 0, 0.3, 0.4, 0.5, 0.6, -1, .infinity, 0.7]
    var set: [(Int, Int, Float)] = []
    for (i, v) in center.enumerated() { set.append((3 + i % 3, 3 + i / 3, v)) }
    #expect(median(grid(width: 10, height: 10, fill: 9, set: set), width: 10, height: 10) == 0.5)
}

@Test func evenCountAveragesMiddlePair() {
    let center: [Float] = [.nan, .nan, .nan, .nan, .nan, 0.2, 0.4, 0.6, 0.8]
    var set: [(Int, Int, Float)] = []
    for (i, v) in center.enumerated() { set.append((3 + i % 3, 3 + i / 3, v)) }
    let m = median(grid(width: 10, height: 10, fill: 9, set: set), width: 10, height: 10)
    #expect(abs((m ?? 0) - 0.5) < 1e-6)
}

@Test func allInvalidGivesNil() {
    #expect(median(grid(width: 10, height: 10, fill: .nan), width: 10, height: 10) == nil)
}

@Test func rowPaddingIsSkipped() {
    let values = grid(width: 10, height: 10, rowStride: 16, fill: 0.45, padding: 99)
    #expect(median(values, width: 10, height: 10, rowStride: 16) == 0.45)
}

@Test func tooSmallBufferGivesNil() {
    #expect(median([Float](repeating: 0.4, count: 50), width: 10, height: 10) == nil)
    #expect(median([], width: 0, height: 0) == nil)
}

@Test func statusThresholds() {
    #expect(DistanceEstimator.status(forMedian: nil) == .noData)
    #expect(DistanceEstimator.status(forMedian: 0.2) == .tooClose(meters: 0.2))
    #expect(DistanceEstimator.status(forMedian: 0.25) == .ok(meters: 0.25))
    #expect(DistanceEstimator.status(forMedian: 0.70) == .ok(meters: 0.70))
    #expect(DistanceEstimator.status(forMedian: 0.71) == .tooFar(meters: 0.71))
}

@Test func messages() {
    #expect(DistanceStatus.noData.message == "Brak danych głębi")
    #expect(DistanceStatus.tooClose(meters: 0.1).message == "Odsuń się")
    #expect(DistanceStatus.tooFar(meters: 1).message == "Przybliż się")
    #expect(DistanceStatus.ok(meters: 0.423).message == "OK — odległość 42 cm")
}
```

- [ ] **Step 3: Run — expect FAIL (compile error, `DistanceEstimator` missing)**

Run: `cd FidmaaCore && swift test`

- [ ] **Step 4: Implementation**

```swift
/// Result of checking how far the subject is from the TrueDepth camera.
public enum DistanceStatus: Equatable, Sendable {
    case noData
    case tooClose(meters: Float)
    case tooFar(meters: Float)
    case ok(meters: Float)

    public var message: String {
        switch self {
        case .noData: "Brak danych głębi"
        case .tooClose: "Odsuń się"
        case .tooFar: "Przybliż się"
        case .ok(let meters): "OK — odległość \(Int((meters * 100).rounded())) cm"
        }
    }
}

public enum DistanceEstimator {
    public static let minDistance: Float = 0.25
    public static let maxDistance: Float = 0.70
    /// Fraction of width and height used for the central measurement window.
    public static let centerFraction = 0.3

    /// Median of valid (finite, > 0) depth values in the central window.
    /// `rowStride` is the row length in elements, including any padding.
    public static func medianCenterDepth(_ values: UnsafeBufferPointer<Float>,
                                         width: Int, height: Int, rowStride: Int) -> Float? {
        guard width > 0, height > 0, rowStride >= width,
              values.count >= rowStride * (height - 1) + width else { return nil }
        let windowWidth = max(1, Int(Double(width) * centerFraction))
        let windowHeight = max(1, Int(Double(height) * centerFraction))
        let x0 = (width - windowWidth) / 2
        let y0 = (height - windowHeight) / 2
        var valid: [Float] = []
        valid.reserveCapacity(windowWidth * windowHeight)
        for y in y0..<(y0 + windowHeight) {
            let row = y * rowStride
            for x in x0..<(x0 + windowWidth) {
                let value = values[row + x]
                if value.isFinite && value > 0 { valid.append(value) }
            }
        }
        guard !valid.isEmpty else { return nil }
        valid.sort()
        let mid = valid.count / 2
        return valid.count % 2 == 0 ? (valid[mid - 1] + valid[mid]) / 2 : valid[mid]
    }

    public static func status(forMedian median: Float?) -> DistanceStatus {
        guard let median else { return .noData }
        if median < minDistance { return .tooClose(meters: median) }
        if median > maxDistance { return .tooFar(meters: median) }
        return .ok(meters: median)
    }
}
```

- [ ] **Step 5: Run — expect PASS:** `cd FidmaaCore && swift test`
- [ ] **Step 6: Commit** `git add FidmaaCore && git commit -m "feat: add FidmaaCore package with DistanceEstimator"`

---

### Task 2: Narzędzia — DepthRaw, FourCC, ExifOrientation, Matrix, ExportNaming

**Files:**
- Create: `FidmaaCore/Sources/FidmaaCore/DepthRaw.swift`, `Formatting.swift`, `ExportNaming.swift`
- Test: `FidmaaCore/Tests/FidmaaCoreTests/UtilitiesTests.swift`

**Interfaces:**
- Produces: `DepthRaw.littleEndianData(_: UnsafeBufferPointer<Float>, width:height:rowStride:) -> Data`, `DepthRaw.floats(fromNativeData: Data) -> [Float]`, `FourCC.string(_: UInt32) -> String`, `ExifOrientation.isMirrored(_: Int) -> Bool`, `Matrix.rowMajor(columns: [[Float]]) -> [[Float]]`, `ExportNaming.folderName(for: Date, timeZone: TimeZone) -> String`, `ExportNaming.createUniqueFolder(in: URL, date: Date, timeZone: TimeZone, fileManager: FileManager) throws -> URL`.

- [ ] **Step 1: Failing tests**

```swift
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
```

- [ ] **Step 2: Run — expect FAIL (missing symbols):** `cd FidmaaCore && swift test`

- [ ] **Step 3: Implementation**

`DepthRaw.swift`:
```swift
import Foundation

public enum DepthRaw {
    /// Packs float rows into little-endian bytes, dropping per-row padding.
    public static func littleEndianData(_ values: UnsafeBufferPointer<Float>,
                                        width: Int, height: Int, rowStride: Int) -> Data {
        precondition(height == 0 || values.count >= rowStride * (height - 1) + width,
                     "buffer too small for \(width)x\(height) stride \(rowStride)")
        var data = Data(capacity: width * height * MemoryLayout<Float>.size)
        for y in 0..<height {
            for x in 0..<width {
                var bits = values[y * rowStride + x].bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// Decodes native-endian Float32 values (e.g. lens distortion lookup tables).
    public static func floats(fromNativeData data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
    }
}
```

`Formatting.swift`:
```swift
public enum FourCC {
    public static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum ExifOrientation {
    /// EXIF orientations 2, 4, 5 and 7 include a horizontal flip.
    public static func isMirrored(_ orientation: Int) -> Bool {
        [2, 4, 5, 7].contains(orientation)
    }
}

public enum Matrix {
    /// Converts column-major storage (simd layout) to an array of rows.
    public static func rowMajor(columns: [[Float]]) -> [[Float]] {
        guard let rowCount = columns.first?.count else { return [] }
        return (0..<rowCount).map { row in columns.map { $0[row] } }
    }
}
```

`ExportNaming.swift`:
```swift
import Foundation

public enum ExportNaming {
    public static func folderName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Creates `<base>/<yyyyMMdd-HHmmss>` or, if taken, `...-2`, `...-3`, ...
    public static func createUniqueFolder(in base: URL, date: Date, timeZone: TimeZone = .current,
                                          fileManager: FileManager = .default) throws -> URL {
        let name = folderName(for: date, timeZone: timeZone)
        var candidate = base.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }
}
```

- [ ] **Step 4: Run — expect PASS:** `cd FidmaaCore && swift test`
- [ ] **Step 5: Commit** `git commit -am "feat: add depth packing, formatting and export naming utilities"` (plus `git add` new files)

---

### Task 3: CaptureMetadata (calibration.json)

**Files:**
- Create: `FidmaaCore/Sources/FidmaaCore/CaptureMetadata.swift`
- Test: `FidmaaCore/Tests/FidmaaCoreTests/CaptureMetadataTests.swift`

**Interfaces:**
- Produces: `DepthAccuracyLabel` (`absolute|relative|unknown`), `Size2D`, `Point2D`, `DepthInfo(width:height:accuracy:quality:isFiltered:originalPixelFormat:)`, `ImageInfo(width:height:exifOrientation:mirrored:)`, `CalibrationInfo(intrinsicMatrix:intrinsicMatrixReferenceDimensions:extrinsicMatrix:pixelSizeMillimeters:lensDistortionCenter:lensDistortionLookupTable:inverseLensDistortionLookupTable:)`, `MatteFiles` (optional `portrait, hair, skin, teeth, glasses`), `CaptureMetadata(captureDate:deviceModel:systemVersion:depth:image:calibration:mattes:distanceAtCaptureMeters:)`, `func jsonData() throws -> Data`, `static func decode(_ data: Data) throws -> CaptureMetadata`.

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import FidmaaCore

private func sample(calibration: CalibrationInfo? = nil, distance: Float? = 0.42) -> CaptureMetadata {
    CaptureMetadata(
        captureDate: Date(timeIntervalSince1970: 1_790_000_000),
        deviceModel: "iPhone18,1",
        systemVersion: "26.5.0",
        depth: DepthInfo(width: 640, height: 480, accuracy: .absolute, quality: "high",
                         isFiltered: false, originalPixelFormat: "fdep"),
        image: ImageInfo(width: 4032, height: 3024, exifOrientation: 5, mirrored: true),
        calibration: calibration,
        mattes: MatteFiles(portrait: "portrait.png", hair: "hair.png", skin: nil, teeth: "teeth.png", glasses: nil),
        distanceAtCaptureMeters: distance)
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func missingValuesAreExplicitNulls() throws {
    let json = try object(sample(calibration: nil, distance: nil).jsonData())
    #expect(json["calibration"] is NSNull)
    #expect(json["distanceAtCapture_m"] is NSNull)
    let mattes = try #require(json["mattes"] as? [String: Any])
    #expect(mattes["skin"] is NSNull)
    #expect(mattes["glasses"] is NSNull)
    #expect(mattes["hair"] as? String == "hair.png")
}

@Test func depthSectionFields() throws {
    let json = try object(sample().jsonData())
    let depth = try #require(json["depth"] as? [String: Any])
    #expect(depth["accuracy"] as? String == "absolute")
    #expect(depth["units"] as? String == "meters")
    #expect(depth["pixelFormat"] as? String == "DepthFloat32")
    #expect(depth["isFiltered"] as? Bool == false)
    #expect(json["captureDate"] as? String == "2026-09-21T13:46:40Z")
}

@Test func calibrationKeysAndRoundTrip() throws {
    let calibration = CalibrationInfo(
        intrinsicMatrix: [[1000, 0, 320], [0, 1000, 240], [0, 0, 1]],
        intrinsicMatrixReferenceDimensions: Size2D(width: 4032, height: 3024),
        extrinsicMatrix: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
        pixelSizeMillimeters: 0.001,
        lensDistortionCenter: Point2D(x: 2016, y: 1512),
        lensDistortionLookupTable: [0, 0.1],
        inverseLensDistortionLookupTable: [0, -0.1])
    let metadata = sample(calibration: calibration)
    let data = try metadata.jsonData()
    let cal = try #require(try object(data)["calibration"] as? [String: Any])
    #expect(cal["pixelSize_mm"] != nil)
    #expect(try CaptureMetadata.decode(data) == metadata)
}

@Test func nanDistanceDoesNotThrow() throws {
    let json = try object(sample(distance: .nan).jsonData())
    #expect(json["distanceAtCapture_m"] as? String == "NaN")
}
```

- [ ] **Step 2: Run — expect FAIL:** `cd FidmaaCore && swift test`

- [ ] **Step 3: Implementation**

```swift
import Foundation

public enum DepthAccuracyLabel: String, Codable, Sendable {
    case absolute, relative, unknown
}

public struct Size2D: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct Point2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct DepthInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var units = "meters"
    public var pixelFormat = "DepthFloat32"
    public var accuracy: DepthAccuracyLabel
    public var quality: String
    public var isFiltered: Bool
    public var originalPixelFormat: String
    public var invalidValue = "NaN or 0 (treat both as invalid)"

    public init(width: Int, height: Int, accuracy: DepthAccuracyLabel, quality: String,
                isFiltered: Bool, originalPixelFormat: String) {
        self.width = width
        self.height = height
        self.accuracy = accuracy
        self.quality = quality
        self.isFiltered = isFiltered
        self.originalPixelFormat = originalPixelFormat
    }
}

public struct ImageInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var exifOrientation: Int
    public var mirrored: Bool
    public init(width: Int, height: Int, exifOrientation: Int, mirrored: Bool) {
        self.width = width
        self.height = height
        self.exifOrientation = exifOrientation
        self.mirrored = mirrored
    }
}

public struct CalibrationInfo: Codable, Equatable, Sendable {
    /// Row-major 3x3, in pixels of `intrinsicMatrixReferenceDimensions`.
    public var intrinsicMatrix: [[Float]]
    public var intrinsicMatrixReferenceDimensions: Size2D
    /// Row-major 3x4 [R|t].
    public var extrinsicMatrix: [[Float]]
    public var pixelSizeMillimeters: Float
    public var lensDistortionCenter: Point2D
    public var lensDistortionLookupTable: [Float]
    public var inverseLensDistortionLookupTable: [Float]

    enum CodingKeys: String, CodingKey {
        case intrinsicMatrix, intrinsicMatrixReferenceDimensions, extrinsicMatrix
        case pixelSizeMillimeters = "pixelSize_mm"
        case lensDistortionCenter, lensDistortionLookupTable, inverseLensDistortionLookupTable
    }

    public init(intrinsicMatrix: [[Float]], intrinsicMatrixReferenceDimensions: Size2D,
                extrinsicMatrix: [[Float]], pixelSizeMillimeters: Float, lensDistortionCenter: Point2D,
                lensDistortionLookupTable: [Float], inverseLensDistortionLookupTable: [Float]) {
        self.intrinsicMatrix = intrinsicMatrix
        self.intrinsicMatrixReferenceDimensions = intrinsicMatrixReferenceDimensions
        self.extrinsicMatrix = extrinsicMatrix
        self.pixelSizeMillimeters = pixelSizeMillimeters
        self.lensDistortionCenter = lensDistortionCenter
        self.lensDistortionLookupTable = lensDistortionLookupTable
        self.inverseLensDistortionLookupTable = inverseLensDistortionLookupTable
    }
}

/// File names of exported mattes; `nil` (written as JSON null) when the camera delivered none.
public struct MatteFiles: Codable, Equatable, Sendable {
    public var portrait: String?
    public var hair: String?
    public var skin: String?
    public var teeth: String?
    public var glasses: String?

    enum CodingKeys: String, CodingKey { case portrait, hair, skin, teeth, glasses }

    public init(portrait: String? = nil, hair: String? = nil, skin: String? = nil,
                teeth: String? = nil, glasses: String? = nil) {
        self.portrait = portrait
        self.hair = hair
        self.skin = skin
        self.teeth = teeth
        self.glasses = glasses
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(portrait, forKey: .portrait)
        try container.encode(hair, forKey: .hair)
        try container.encode(skin, forKey: .skin)
        try container.encode(teeth, forKey: .teeth)
        try container.encode(glasses, forKey: .glasses)
    }
}

public struct CaptureMetadata: Codable, Equatable, Sendable {
    public var captureDate: Date
    public var deviceModel: String
    public var systemVersion: String
    public var depth: DepthInfo?
    public var image: ImageInfo
    public var calibration: CalibrationInfo?
    public var mattes: MatteFiles
    public var distanceAtCaptureMeters: Float?

    enum CodingKeys: String, CodingKey {
        case captureDate, deviceModel, systemVersion, depth, image, calibration, mattes
        case distanceAtCaptureMeters = "distanceAtCapture_m"
    }

    public init(captureDate: Date, deviceModel: String, systemVersion: String, depth: DepthInfo?,
                image: ImageInfo, calibration: CalibrationInfo?, mattes: MatteFiles,
                distanceAtCaptureMeters: Float?) {
        self.captureDate = captureDate
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.depth = depth
        self.image = image
        self.calibration = calibration
        self.mattes = mattes
        self.distanceAtCaptureMeters = distanceAtCaptureMeters
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureDate, forKey: .captureDate)
        try container.encode(deviceModel, forKey: .deviceModel)
        try container.encode(systemVersion, forKey: .systemVersion)
        try container.encode(depth, forKey: .depth)
        try container.encode(image, forKey: .image)
        try container.encode(calibration, forKey: .calibration)
        try container.encode(mattes, forKey: .mattes)
        try container.encode(distanceAtCaptureMeters, forKey: .distanceAtCaptureMeters)
    }

    private static let nonConforming = (positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: Self.nonConforming.positiveInfinity,
            negativeInfinity: Self.nonConforming.negativeInfinity,
            nan: Self.nonConforming.nan)
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CaptureMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: nonConforming.positiveInfinity,
            negativeInfinity: nonConforming.negativeInfinity,
            nan: nonConforming.nan)
        return try decoder.decode(CaptureMetadata.self, from: data)
    }
}
```

- [ ] **Step 4: Run — expect PASS:** `cd FidmaaCore && swift test`
- [ ] **Step 5: Commit** `git add FidmaaCore && git commit -m "feat: add CaptureMetadata JSON model"`

---

### Task 4: Projekt Xcode + szkielet aplikacji (podgląd kamery)

**Files:**
- Create: `FidmaaPic.xcodeproj/project.pbxproj`, `FidmaaPic-Info.plist`, `FidmaaPic/FidmaaPicApp.swift`, `FidmaaPic/CameraPreviewView.swift`, `FidmaaPic/ContentView.swift` (tymczasowy: sam podgląd), `FidmaaPic/CameraController.swift` (tymczasowy: sesja + start/stop), `.gitignore` (dopisać `build/`)

**Interfaces:**
- Produces: `CameraPreviewView(session: AVCaptureSession, isRunning: Bool)`; target `FidmaaPic` linkujący produkt `FidmaaCore`.

- [ ] **Step 1: `project.pbxproj`** — objectVersion 77, jeden target aplikacji z `PBXFileSystemSynchronizedRootGroup` (`path = FidmaaPic`), `XCLocalSwiftPackageReference` (`relativePath = FidmaaCore`) + `XCSwiftPackageProductDependency` (`productName = FidmaaCore`) + `PBXBuildFile` w fazie Frameworks. Ustawienia targetu: `GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_FILE = "FidmaaPic-Info.plist"`, `INFOPLIST_KEY_NSCameraUsageDescription`, `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription`, `INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait`, `INFOPLIST_KEY_UILaunchScreen_Generation = YES`, `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`, `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 5.0`, `TARGETED_DEVICE_FAMILY = 1`, `PRODUCT_BUNDLE_IDENTIFIER = com.fidmaa.pic`, `CODE_SIGN_STYLE = Automatic`. (Pełna treść pliku — patrz commit; generowana wg struktury powyżej.)

- [ ] **Step 2: `FidmaaPic-Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>front-facing-camera</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: App, preview view, minimal controller** (kod jak w Task 5 — `CameraController.start()/stop()` i `session`; `ContentView` pokazuje `CameraPreviewView`).

- [ ] **Step 4: Build**

Run: `xcodebuild -project FidmaaPic.xcodeproj -scheme FidmaaPic -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`; `plutil -p build/DerivedData/Build/Products/Debug-iphoneos/FidmaaPic.app/Info.plist` zawiera `UIFileSharingEnabled`, `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`.

- [ ] **Step 5: Commit** `git commit -m "feat: add Xcode project and camera preview skeleton"`

---

### Task 5: Konfiguracja sesji TrueDepth + komunikat odległości

**Files:**
- Modify: `FidmaaPic/CameraController.swift`, `FidmaaPic/ContentView.swift`
- Create: `FidmaaPic/PixelBufferAccess.swift`

**Interfaces:**
- Consumes: `DistanceEstimator`, `DistanceStatus` (Task 1).
- Produces: `CameraController` (`@Observable`): `state: State` (`.idle/.running/.failed(String)`), `distance: DistanceStatus`, `session`, `start()`, `stop()`; `PixelBufferAccess.withFloat32(_:_:) -> T?`.

Kluczowe decyzje (kod w pliku):
- `sessionPreset = .photo`, dodanie inputu, `AVCapturePhotoOutput`, `AVCaptureDepthDataOutput` (filtrowany, delegate na `depthQueue`; brak możliwości dodania → log, bez błędu fatalnego).
- Wybór formatu: spośród `device.formats` z niepustym `supportedDepthDataFormats` — max po (ma DepthFloat32, 8-bit full range 420f, pole `supportedMaxPhotoDimensions`).
- Po `activeFormat`: `photoOutput.isDepthDataDeliveryEnabled = true`, `isPortraitEffectsMatteDeliveryEnabled = isPortraitEffectsMatteDeliverySupported`, `enabledSemanticSegmentationMatteTypes = availableSemanticSegmentationMatteTypes`, `maxPhotoDimensions`, a na końcu `activeDepthDataFormat` = największy float32 (fallback: największy dowolny).
- Delegate głębi: co ≥ 0,1 s konwersja do float32 → `DistanceEstimator.medianCenterDepth` → `OSAllocatedUnfairLock<Float?>` + `distance` na main.
- UI: kapsuła z `distance.message` (zielona OK, pomarańczowa za blisko/daleko, szara brak danych); `.failed` → tekst błędu.

- [ ] **Step 1:** Implementacja. **Step 2:** Build (komenda z Task 4) → `BUILD SUCCEEDED`. **Step 3:** Commit `feat: configure TrueDepth session and live distance hint`.

---

### Task 6: Zdjęcie + eksport (pliki, Zdjęcia) + panel wyniku

**Files:**
- Create: `FidmaaPic/PhotoCaptureProcessor.swift`, `CaptureExporter.swift`, `ImageFileWriter.swift`, `PhotoLibrarySaver.swift`, `DeviceInfo.swift`
- Modify: `FidmaaPic/CameraController.swift` (`capturePhoto()`, `isCapturing`, `lastResult`, `lastError`), `FidmaaPic/ContentView.swift` (migawka, miniatura, panel)

**Interfaces:**
- Consumes: wszystko z Task 1–3, `PixelBufferAccess` (Task 5).
- Produces: `CaptureResult { folder: URL; accuracy: DepthAccuracyLabel; thumbnail: UIImage?; warnings: [String] }`, `CaptureExporter.export(photo:distance:date:) async throws -> CaptureResult`, `ImageFileWriter.writeFloat32TIFF(_:to:)`, `ImageFileWriter.writeGray8PNG(_:to:)`, `PhotoLibrarySaver.save(_: Data) async throws`.

Kluczowe decyzje:
- Ustawienia zdjęcia: HEVC jeśli dostępny, `maxPhotoDimensions`, `.quality`, depth + embed, `isDepthDataFiltered = false`, portrait matte + embed, semantic mattes + embed; `videoRotationAngle = 90` na połączeniu zdjęcia.
- `PhotoCaptureProcessor`: `didFinishProcessingPhoto` → `Task.detached` z eksportem → `completion` dokładnie raz; `didFinishCaptureFor` bez zdjęcia → `completion(.failure)`.
- Eksport: folder unikalny; `photo.heic` z `fileDataRepresentation()` (brak → throw); głębia `converting(toDepthDataType: DepthFloat32)` → `depth.tiff` (CGImage float32 1-kanał, linearGray, ImageIO TIFF) i `depth.f32` (`DepthRaw.littleEndianData`); maski `mattingImage` (OneComponent8) → PNG; `calibration.json`; zapis do Zdjęć `PHAssetCreationRequest` `.photo` (add-only). Każdy krok w `attempt` → błąd do `Logger` + `warnings`, reszta kontynuowana. `.relative` → ostrzeżenie.
- UI: migawka (wyłączona podczas zapisu), miniatura, „Zapisano: <folder>”, „Głębia: ABSOLUTE/RELATIVE”, ostrzeżenia.

- [ ] **Step 1:** Implementacja. **Step 2:** Build → `BUILD SUCCEEDED`, `swift test` nadal PASS. **Step 3:** Commit `feat: capture portrait photo with depth and mattes, export to Files and Photos`.

---

### Task 7: README (Python + checklista ręczna)

**Files:** Create `README.md`

Zawartość: wymagania (iPhone z TrueDepth, iOS 26), ustawienie Team w Xcode, gdzie są pliki (Pliki → Na moim iPhonie → Fidmaa Pic; Finder → iPhone → Pliki), opis plików, snippet Pythona:

```python
import json
import numpy as np

meta = json.load(open("calibration.json"))
h, w = meta["depth"]["height"], meta["depth"]["width"]
depth = np.fromfile("depth.f32", dtype="<f4").reshape(h, w)   # metry, orientacja sensora
valid = np.isfinite(depth) & (depth > 0)

cal = meta["calibration"]
K = np.array(cal["intrinsicMatrix"], dtype=np.float64)
scale = w / cal["intrinsicMatrixReferenceDimensions"]["width"]
K_depth = K.copy()
K_depth[:2] *= scale                                             # intrinsics w pikselach mapy głębi

ys, xs = np.nonzero(valid)
z = depth[ys, xs]
X = (xs - K_depth[0, 2]) * z / K_depth[0, 0]
Y = (ys - K_depth[1, 2]) * z / K_depth[1, 1]
points = np.column_stack([X, Y, z])                              # chmura punktów w metrach
```

Checklista ręczna na urządzeniu: zgoda na aparat; komunikaty „Odsuń się”/„Przybliż się”/„OK”; zdjęcie → folder w Plikach z 9 plikami; `accuracy: "absolute"`; zdjęcie w Zdjęciach ma efekt Portret; zdjęcie bez twarzy → maski `null`, reszta plików jest.

- [ ] **Step 1:** Napisz. **Step 2:** Commit `docs: add README with Python loading example`.
