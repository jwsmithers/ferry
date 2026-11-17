import AppKit
import UniformTypeIdentifiers

struct RemoteFile: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isBrokenLink: Bool
    let size: Int64
    let modified: Date

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
}

enum RemotePath {
    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for file: RemoteFile) -> NSImage {
        let key = file.isDirectory ? "/folder" : (file.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = file.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

enum LocalFiles {
    /// "name.ext", or "name 2.ext", "name 3.ext"… if taken (like Finder).
    static func uniqueURL(in dir: URL, name: String, reserved: Set<String> = []) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || reserved.contains(url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func size(of url: URL) -> Int64 {
        if !isDirectory(url) {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let f as URL in e {
                if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                    total += Int64(v.fileSize ?? 0)
                }
            }
        }
        return total
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// Files opened with double-click go to the per-user temp folder, which macOS wipes on
    /// restart; Ferry also clears it on each launch (see `clearOpenedFiles`).
    static var openedFilesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Ferry-opened")
    }

    static func cacheURL(host: String, remotePath: String) -> URL {
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
        return openedFilesFolder.appendingPathComponent(safeHost)
            .appendingPathComponent(String(remotePath.drop(while: { $0 == "/" })))
    }

    /// Done at launch rather than quit, so files still open in Preview etc. aren't pulled away.
    static func clearOpenedFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: openedFilesFolder)
        // Older builds used ~/Library/Caches/Ferry.
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("Ferry"))
        }
    }
}
