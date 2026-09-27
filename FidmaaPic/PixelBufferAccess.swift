import CoreVideo

enum PixelBufferAccess {
    /// Runs `body` with read-only access to a single-plane DepthFloat32 buffer.
    /// Returns nil if the buffer has another pixel format or no base address.
    static func withFloat32<T>(
        _ buffer: CVPixelBuffer,
        _ body: (_ values: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ rowStride: Int) -> T
    ) -> T? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowStride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        let values = UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self), count: rowStride * height)
        return body(values, width, height, rowStride)
    }
}
