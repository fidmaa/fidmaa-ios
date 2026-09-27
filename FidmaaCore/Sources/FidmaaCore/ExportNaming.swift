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
