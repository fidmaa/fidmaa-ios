// Extracts the depth auxiliary image of a HEIC as Float32 (values as labelled: disparity 1/m or depth m).
// Prints one JSON line with width, height, label, accuracy and calibration.
// usage: xcrun swift tools/heic_depth.swift <photo.heic> <out.f32>
import AVFoundation
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: heic_depth.swift <photo.heic> <out.f32>") }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil) else { fail("cannot read \(args[1])") }
let disparityInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
guard let info = (disparityInfo ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth))
        as? [AnyHashable: Any] else { fail("no depth in \(args[1])") }
let isDisparity = disparityInfo != nil
let original: AVDepthData
do {
    original = try AVDepthData(fromDictionaryRepresentation: info)
} catch {
    fail("cannot decode depth: \(error.localizedDescription)")
}
let data = original.converting(toDepthDataType: isDisparity ? kCVPixelFormatType_DisparityFloat32 : kCVPixelFormatType_DepthFloat32)
let map = data.depthDataMap
CVPixelBufferLockBaseAddress(map, .readOnly)
defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
guard let base = CVPixelBufferGetBaseAddress(map) else { fail("no depth buffer") }
let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map), bytesPerRow = CVPixelBufferGetBytesPerRow(map)
var packed = Data(capacity: width * height * 4)
for y in 0..<height { packed.append(Data(bytes: base + y * bytesPerRow, count: width * 4)) }
do {
    try packed.write(to: URL(fileURLWithPath: args[2]))
} catch {
    fail("cannot write \(args[2]): \(error.localizedDescription)")
}
var result: [String: Any] = ["width": width, "height": height, "label": isDisparity ? "disparity" : "depth",
                             "accuracy": data.depthDataAccuracy == .absolute ? "absolute" : "relative",
                             "originalType": String(format: "%08x", original.depthDataType)]
if let c = data.cameraCalibrationData {
    result["fx"] = c.intrinsicMatrix.columns.0.x
    result["refWidth"] = c.intrinsicMatrixReferenceDimensions.width
    result["refHeight"] = c.intrinsicMatrixReferenceDimensions.height
}
let json = try JSONSerialization.data(withJSONObject: result)
print(String(decoding: json, as: UTF8.self))
