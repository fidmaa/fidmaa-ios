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
