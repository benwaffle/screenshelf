import Foundation
import UniformTypeIdentifiers

/// A file found on disk that should be in the library.
public struct DiscoveredFile: Sendable {
    public var path: String
    public var fileNumber: UInt64
    public var createdAt: Date
    public var fileSize: Int64
}

public enum Scanner {
    /// Default screenshot location: the `screencapture` preference if set, else the Desktop.
    public static var systemScreenshotFolder: URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL.desktopDirectory
    }

    public struct Result: Sendable {
        public var files: [DiscoveredFile]
        /// Folders that couldn't be listed, for example because folder access was denied or a drive is unplugged.
        /// Their files' absence says nothing about whether the files still exist.
        public var unreadable: [URL]
    }

    /// Lists screenshots directly inside `folders` (not recursive).
    ///
    /// A file counts as a screenshot when macOS tagged it with `kMDItemIsScreenCapture` (this survives renames),
    /// or its name starts like one. With `includeAllImages`, every image file counts.
    public static func scan(folders: [URL], includeAllImages: Bool) -> Result {
        let keys: [URLResourceKey] = [.contentTypeKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]
        var result = Result(files: [], unreadable: [])
        for folder in folders {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else {
                result.unreadable.append(folder)
                continue
            }
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let type = values.contentType, type.conforms(to: .image)
                else { continue }
                guard includeAllImages || isScreenCapture(url) || looksLikeScreenshotName(url.lastPathComponent) else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                result.files.append(DiscoveredFile(
                    path: url.path,
                    fileNumber: (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                    createdAt: values.creationDate ?? .now,
                    fileSize: Int64(values.fileSize ?? 0)
                ))
            }
        }
        return result
    }

    static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    static func looksLikeScreenshotName(_ name: String) -> Bool {
        ["Screenshot", "Screen Shot", "CleanShot", "Simulator Screenshot"].contains { name.hasPrefix($0) }
    }
}
