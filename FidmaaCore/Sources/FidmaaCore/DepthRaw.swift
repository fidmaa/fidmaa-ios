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

extension DepthRaw {
    /// Copies rows into a contiguous width*height array, dropping per-row padding.
    public static func packed(_ values: UnsafeBufferPointer<Float>, width: Int, height: Int, rowStride: Int) -> [Float] {
        precondition(height == 0 || values.count >= rowStride * (height - 1) + width,
                     "buffer too small for \(width)x\(height) stride \(rowStride)")
        var result = [Float]()
        result.reserveCapacity(width * height)
        for y in 0..<height {
            result.append(contentsOf: values[(y * rowStride)..<(y * rowStride + width)])
        }
        return result
    }

    /// Concatenates packed frames as little-endian Float32.
    public static func littleEndianData(frames: [[Float]]) -> Data {
        var data = Data(capacity: frames.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.size)
        for frame in frames {
            frame.withUnsafeBufferPointer {
                data.append(littleEndianData($0, width: frame.count, height: 1, rowStride: frame.count))
            }
        }
        return data
    }
}
