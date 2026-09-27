import FidmaaCore
import Foundation

enum CaptureArchiver {
    /// Zips each capture folder into `<tmp>/share-<uuid>/<folder>.zip` (one archive per capture,
    /// so files with the same names from different captures don't collide at the destination).
    static func zipCaptures(_ folders: [URL]) throws -> [URL] {
        try removeOldShares()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try folders.map { folder in
            let destination = directory.appendingPathComponent("\(folder.lastPathComponent).zip")
            try zip(folder, to: destination)
            return destination
        }
    }

    enum DepthVariant {
        /// Single-frame depth from the photo (depth.f32, already corrected to meters).
        case single
        /// Per-pixel median of the streamed frames (depth_median.f32).
        case averaged
    }

    enum ArchiverError: LocalizedError {
        case missingDepth(String)

        var errorDescription: String? {
            switch self {
            case .missingDepth(let folder): "Brak mapy głębi w \(folder)"
            }
        }
    }

    /// Writes `<tmp>/share-<uuid>/<folder>[-avg].heic` with the chosen depth map embedded as meters.
    static func exportPhotos(_ folders: [URL], variant: DepthVariant) throws -> [URL] {
        try removeOldShares()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try folders.map { folder in
            let metadata = try CaptureMetadata.decode(Data(contentsOf: folder.appendingPathComponent("calibration.json")))
            let (file, width, height): (String, Int?, Int?) = switch variant {
            case .single: ("depth.f32", metadata.depth?.width, metadata.depth?.height)
            case .averaged: ("depth_median.f32", metadata.stack?.width, metadata.stack?.height)
            }
            let depthURL = folder.appendingPathComponent(file)
            guard let width, let height, fm.fileExists(atPath: depthURL.path) else {
                throw ArchiverError.missingDepth(folder.lastPathComponent)
            }
            let values = DepthRaw.floats(fromNativeData: try Data(contentsOf: depthURL))
            guard values.count == width * height else { throw ArchiverError.missingDepth(folder.lastPathComponent) }
            let suffix = variant == .averaged ? "-avg" : ""
            let destination = directory.appendingPathComponent("\(folder.lastPathComponent)\(suffix).heic")
            try HEICComposer.write(photo: folder.appendingPathComponent("photo.heic"), depth: values,
                                   width: width, height: height, to: destination)
            return destination
        }
    }

    /// Removes share directories from earlier shares. Done before a new share rather than right
    /// after the share sheet closes, so the receiving app can finish reading the files.
    static func removeOldShares() throws {
        let fm = FileManager.default
        for url in try fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("share-") {
            try fm.removeItem(at: url)
        }
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
