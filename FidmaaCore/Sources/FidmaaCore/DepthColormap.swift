/// Turbo colormap for depth: near = red, far = blue, invalid = black.
public enum DepthColormap {
    public static let nearMeters: Float = 0.2
    public static let farMeters: Float = 1.2

    public static func color(depth: Float, near: Float = nearMeters,
                             far: Float = farMeters) -> (r: UInt8, g: UInt8, b: UInt8) {
        guard depth.isFinite && depth > 0 else { return (0, 0, 0) }
        let normalized = Double(min(max((depth - near) / (far - near), 0), 1))
        let (r, g, b) = turbo(1 - normalized)
        return (byte(r), byte(g), byte(b))
    }

    /// RGBA bytes (alpha 255) for packed depth values.
    public static func rgba(_ values: [Float], near: Float = nearMeters, far: Float = farMeters) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: values.count * 4)
        for (i, value) in values.enumerated() {
            let c = color(depth: value, near: near, far: far)
            bytes[i * 4] = c.r
            bytes[i * 4 + 1] = c.g
            bytes[i * 4 + 2] = c.b
        }
        return bytes
    }

    /// Polynomial approximation of Google's Turbo colormap, t in 0...1 (0 = blue, 1 = red).
    public static func turbo(_ t: Double) -> (Double, Double, Double) {
        let r = 0.13572138 + t * (4.61539260 + t * (-42.66032258 + t * (132.13108234 + t * (-152.94239396 + t * 59.28637943))))
        let g = 0.09140261 + t * (2.19418839 + t * (4.84296658 + t * (-14.18503333 + t * (4.27729857 + t * 2.82956604))))
        let b = 0.10667330 + t * (12.64194608 + t * (-60.58204836 + t * (110.36276771 + t * (-89.90310912 + t * 27.34824973))))
        return (r, g, b)
    }

    private static func byte(_ v: Double) -> UInt8 {
        UInt8((min(max(v, 0), 1) * 255).rounded())
    }
}
