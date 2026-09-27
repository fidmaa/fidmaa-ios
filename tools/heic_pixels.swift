// Writes a HEIC's stored pixels (no EXIF rotation, i.e. the same grid as the depth map) as a JPEG.
// usage: xcrun swift tools/heic_pixels.swift <photo.heic> <out.jpg> <width> <height>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 5, let width = Int(args[3]), let height = Int(args[4]) else {
    FileHandle.standardError.write("usage: heic_pixels.swift <photo.heic> <out.jpg> <width> <height>\n".data(using: .utf8)!)
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let scaled = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                        UTType.jpeg.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot create \(args[2])\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("cannot write \(args[2])\n".data(using: .utf8)!)
    exit(1)
}
