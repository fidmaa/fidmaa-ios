import Foundation

public enum CaptureLibrary {
    /// Capture folders (containing photo.heic) in `base`, newest first.
    public static func captureFolders(in base: URL, fileManager: FileManager = .default) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("photo.heic").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// "20260927-203837[-2]" → "27.09 20:38:37[ (2)]"; other names unchanged.
    public static func displayName(forFolder name: String) -> String {
        let parts = name.split(separator: "-")
        guard parts.count >= 2, parts[0].count == 8, parts[1].count == 6,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) else { return name }
        let d = Array(parts[0])
        let t = Array(parts[1])
        var result = "\(d[6])\(d[7]).\(d[4])\(d[5]) \(t[0])\(t[1]):\(t[2])\(t[3]):\(t[4])\(t[5])"
        if parts.count > 2 { result += " (\(parts[2]))" }
        return result
    }

    public struct DeletionFailure: Sendable {
        public let folder: URL
        public let message: String
    }

    /// Deletes capture folders; continues past failures and returns them.
    public static func deleteCaptures(_ folders: [URL], fileManager: FileManager = .default) -> [DeletionFailure] {
        folders.compactMap { folder in
            do {
                try fileManager.removeItem(at: folder)
                return nil
            } catch {
                return DeletionFailure(folder: folder, message: error.localizedDescription)
            }
        }
    }
}
