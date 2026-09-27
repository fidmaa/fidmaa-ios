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
