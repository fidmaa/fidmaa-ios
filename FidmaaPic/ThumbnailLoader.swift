import ImageIO
import UIKit

enum ThumbnailLoader {
    /// Downscaled image with the EXIF orientation applied by ImageIO
    /// (UIImage + byPreparingThumbnail showed our exif-6 selfies rotated).
    static func thumbnail(at url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
