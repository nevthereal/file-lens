import Foundation
import UniformTypeIdentifiers

enum SizeState: Sendable {
    /// `stale` is a total from the previous index, shown until the new one finishes.
    case pending, measuring, complete, partial, inaccessible, excluded, stale
}

enum FileCategory: String, CaseIterable, Sendable {
    case folder, app, image, video, audio, archive, code, document, other

    var label: String {
        switch self {
        case .folder: return "Folders"
        case .app: return "Apps"
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .archive: return "Archives"
        case .code: return "Code"
        case .document: return "Documents"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .app: return "app"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }

    static func of(url: URL, isDirectory: Bool, isPackage: Bool) -> FileCategory {
        if isDirectory && !isPackage { return .folder }
        if isPackage { return .app }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .rtf) { return .document }
        return .other
    }
}

struct DiskItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    var isPackage = false
    var bytes: Int64
    var fileCount: Int
    var children: [DiskItem]
    var state: SizeState = .complete
    /// Non-zero for the combined "smaller items" bubble.
    var aggregateCount = 0

    init(url: URL, isDirectory: Bool, isSymbolicLink: Bool, isPackage: Bool = false, bytes: Int64, fileCount: Int,
         children: [DiskItem], state: SizeState = .complete, aggregateCount: Int = 0) {
        self.url = url; self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink; self.isPackage = isPackage
        self.bytes = bytes; self.fileCount = fileCount; self.children = children; self.state = state
        self.aggregateCount = aggregateCount
    }

    var name: String {
        if aggregateCount > 0 { return "\(aggregateCount) smaller items" }
        return url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }
    /// Folders you can browse into. Packages (apps, bundles) behave like files.
    var isBrowsable: Bool { isDirectory && !isPackage && aggregateCount == 0 }
    var category: FileCategory { FileCategory.of(url: url, isDirectory: isDirectory, isPackage: isPackage) }
    var sizeText: String {
        switch state {
        case .pending: return "—"
        case .measuring: return bytes > 0 ? "≥ " + byteText(bytes) : "Measuring…"
        case .partial: return "≥ " + byteText(bytes)
        case .inaccessible: return "No access"
        case .excluded: return "Excluded"
        case .stale: return "≈ " + byteText(bytes)
        case .complete: return byteText(bytes)
        }
    }
    static func placeholder(_ url: URL) -> DiskItem {
        DiskItem(url: url, isDirectory: true, isSymbolicLink: false, bytes: 0, fileCount: 0, children: [], state: .pending)
    }
}

enum DirectoryScanner {
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
                                            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    static func skipsContents(of url: URL, scanRoot: URL) -> Bool {
        IndexEngine.skipsContents(of: url.path, scanRoot: scanRoot.path)
    }

    private static func entry(_ url: URL, scanRoot: URL) -> DiskItem {
        do {
            let values = try url.resourceValues(forKeys: keys)
            let link = values.isSymbolicLink == true
            let directory = values.isDirectory == true && !link
            var item = DiskItem(url: url, isDirectory: directory, isSymbolicLink: link, isPackage: directory && values.isPackage == true,
                                bytes: directory ? 0 : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0),
                                fileCount: directory ? 0 : 1, children: [], state: directory ? .pending : .complete)
            if directory && skipsContents(of: url, scanRoot: scanRoot) { item.state = .excluded }
            return item
        } catch {
            return DiskItem(url: url, isDirectory: false, isSymbolicLink: false, bytes: 0, fileCount: 0, children: [], state: .inaccessible)
        }
    }

    /// One directory only: this never descends into its children. Folder sizes come from the index.
    static func list(_ url: URL, scanRoot: URL) throws -> DiskItem {
        try Task.checkCancellation()
        if skipsContents(of: url, scanRoot: scanRoot) {
            var item = DiskItem.placeholder(url); item.state = .excluded; return item
        }
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        var children: [DiskItem] = []
        children.reserveCapacity(urls.count)
        for child in urls {
            try Task.checkCancellation()
            // Keep the parent's spelling of the path (e.g. /var, not /private/var) so
            // items match the index, which builds paths from the scan root.
            let consistent = url.appendingPathComponent(child.lastPathComponent)
            children.append(entry(consistent, scanRoot: scanRoot))
        }
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        return DiskItem(url: url, isDirectory: true, isSymbolicLink: false, isPackage: isPackage,
                        bytes: children.reduce(0) { $0 + $1.bytes }, fileCount: children.reduce(0) { $0 + $1.fileCount },
                        children: children, state: .pending)
    }
}

/// Folders that File Lens refuses to move to the Trash.
enum TrashPolicy {
    private static let systemRoots = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple"]
    private static let homeFolders: Set<String> = ["Library", "Desktop", "Documents", "Downloads", "Movies",
                                                   "Music", "Pictures", "Public", "Applications"]

    static func isProtected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        if path == "/" { return true }
        // Anything directly at the top of the drive: /Applications, /Users, /Library, …
        if (path as NSString).deletingLastPathComponent == "/" { return true }
        if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == "/Users" || path == homePath { return true }
        if parent == homePath && homeFolders.contains((path as NSString).lastPathComponent) { return true }
        return false
    }
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
