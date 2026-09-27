import Foundation

enum CaptureArchiver {
    /// Zips each capture folder into `<tmp>/share-<uuid>/<folder>.zip` (one archive per capture,
    /// so files with the same names from different captures don't collide at the destination).
    static func zipCaptures(_ folders: [URL]) throws -> [URL] {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try folders.map { folder in
            let destination = directory.appendingPathComponent("\(folder.lastPathComponent).zip")
            try zip(folder, to: destination)
            return destination
        }
    }

    /// Copies each capture's photo.heic to `<tmp>/share-<uuid>/<folder>.heic` (unique names).
    static func exportPhotos(_ folders: [URL]) throws -> [URL] {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try folders.map { folder in
            let destination = directory.appendingPathComponent("\(folder.lastPathComponent).heic")
            try fm.copyItem(at: folder.appendingPathComponent("photo.heic"), to: destination)
            return destination
        }
    }

    /// Removes the temporary directory that holds the given archives.
    static func cleanUp(_ archives: [URL]) throws {
        guard let directory = archives.first?.deletingLastPathComponent() else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Uses NSFileCoordinator's `.forUploading`, which produces a zip of a directory.
    private static func zip(_ folder: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading,
                                       error: &coordinatorError) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }
}
