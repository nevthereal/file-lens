import Foundation

enum SizeState: Sendable {
    case pending, measuring, complete, partial, inaccessible, excluded
}

struct DiskItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    var bytes: Int64
    var fileCount: Int
    var children: [DiskItem]
    var state: SizeState = .complete
    var name: String { url.path == "/" ? "Macintosh HD" : url.lastPathComponent }
    var sizeText: String {
        switch state {
        case .pending: return "—"
        case .measuring: return bytes > 0 ? "≥ " + byteText(bytes) : "Measuring…"
        case .partial: return "≥ " + byteText(bytes)
        case .inaccessible: return "No access"
        case .excluded: return "Excluded"
        case .complete: return byteText(bytes)
        }
    }
    static func placeholder(_ url: URL) -> DiskItem {
        DiskItem(url: url, isDirectory: true, isSymbolicLink: false, bytes: 0, fileCount: 0, children: [], state: .pending)
    }
}

struct Measurement: Sendable {
    var bytes: Int64 = 0
    var files = 0
    var unreadable = 0
    var state: SizeState = .complete
}

/// Only finished directory totals are retained, not millions of file nodes.
/// A cancelled traversal can reuse completed subtrees when navigation resumes it.
final class MeasurementCache: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: [String: Measurement] = [:]
    func value(for url: URL) -> Measurement? {
        lock.lock(); defer { lock.unlock() }
        return totals[url.path]
    }
    func store(_ value: Measurement, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        totals[url.path] = value
    }

}

struct ScanProgress: Sendable {
    let sequence: Int
    let total: Measurement
    let children: [DiskItem]
    let visited: Int
    let fraction: Double
}

struct ScanResult: Sendable {
    let root: DiskItem
    let unreadable: Int
}

enum DirectoryScanner {
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    static func skipsContents(of url: URL, scanRoot: URL) -> Bool {
        scanRoot.standardizedFileURL.path == "/" &&
            ["/System/Volumes", "/Volumes", "/dev", "/Network", "/.vol"].contains(url.standardizedFileURL.path)
    }

    private static func entry(_ url: URL, scanRoot: URL, cache: MeasurementCache) -> DiskItem {
        do {
            let values = try url.resourceValues(forKeys: keys)
            let link = values.isSymbolicLink == true
            let directory = values.isDirectory == true && !link
            var item = DiskItem(url: url, isDirectory: directory, isSymbolicLink: link,
                                bytes: directory ? 0 : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0),
                                fileCount: directory ? 0 : 1, children: [], state: directory ? .pending : .complete)
            if directory {
                if skipsContents(of: url, scanRoot: scanRoot) { item.state = .excluded }
                else if let total = cache.value(for: url) { item.bytes = total.bytes; item.fileCount = total.files; item.state = total.state }
            }
            return item
        } catch {
            return DiskItem(url: url, isDirectory: false, isSymbolicLink: false, bytes: 0, fileCount: 0, children: [], state: .inaccessible)
        }
    }

    /// One directory only: this never descends into its children.
    static func list(_ url: URL, scanRoot: URL, cache: MeasurementCache) throws -> DiskItem {
        try Task.checkCancellation()
        if skipsContents(of: url, scanRoot: scanRoot) {
            var item = DiskItem.placeholder(url); item.state = .excluded; return item
        }
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        var children: [DiskItem] = []
        for child in urls {
            try Task.checkCancellation()
            children.append(entry(child, scanRoot: scanRoot, cache: cache))
        }
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let known = cache.value(for: url)
        return DiskItem(url: url, isDirectory: true, isSymbolicLink: false,
                        bytes: known?.bytes ?? children.reduce(0) { $0 + $1.bytes },
                        fileCount: known?.files ?? children.reduce(0) { $0 + $1.fileCount },
                        children: children, state: known?.state ?? .pending)
    }

    /// Measures in the background, publishing partial totals at most five times
    /// per second. Navigation cancels this work and starts with the visible folder.
    static func measure(_ listing: DiskItem, scanRoot: URL, cache: MeasurementCache, progressInterval: TimeInterval = 0.2,
                        progress: @Sendable (ScanProgress) -> Void) throws -> ScanResult {
        var total = Measurement()
        var visited = 0
        var sequence = 0
        var completedWork = 0.0
        var lastEmission = Date.timeIntervalSinceReferenceDate
        var active = listing
        var before = Measurement()
        var changes: [String: DiskItem] = [:]
        func emit(force: Bool = false, finished: DiskItem? = nil) {
            if let finished { changes[finished.id] = finished }
            let now = Date.timeIntervalSinceReferenceDate
            guard force || now - lastEmission >= progressInterval else { return }
            lastEmission = now
            var child = finished ?? active
            if finished == nil {
                child.bytes = total.bytes - before.bytes
                child.fileCount = total.files - before.files
                child.state = .measuring
            }
            changes[child.id] = child
            sequence += 1
            progress(ScanProgress(sequence: sequence, total: total, children: Array(changes.values), visited: visited, fraction: min(1, completedWork)))
            changes.removeAll(keepingCapacity: true)
        }
        func add(_ value: Measurement) {
            total.bytes += value.bytes; total.files += value.files; total.unreadable += value.unreadable
        }
        func walk(_ item: DiskItem, weight: Double) throws -> Measurement {
            try Task.checkCancellation()
            visited += 1
            if item.state == .excluded { completedWork += weight; return Measurement(state: .excluded) }
            if item.state == .inaccessible {
                let value = Measurement(unreadable: 1, state: .inaccessible); add(value); completedWork += weight; return value
            }
            if !item.isDirectory {
                let value = Measurement(bytes: item.bytes, files: 1); add(value); completedWork += weight; emit(); return value
            }
            if let cached = cache.value(for: item.url) { add(cached); completedWork += weight; emit(); return cached }
            let start = total
            let urls: [URL]
            do { urls = try FileManager.default.contentsOfDirectory(at: item.url, includingPropertiesForKeys: Array(keys)) }
            catch {
                let value = Measurement(unreadable: 1, state: .inaccessible)
                add(value); completedWork += weight; cache.store(value, for: item.url); return value
            }
            if urls.isEmpty { completedWork += weight }
            for url in urls {
                try Task.checkCancellation()
                // Bound Foundation's autoreleased metadata during large scans.
                try autoreleasepool {
                    _ = try walk(entry(url, scanRoot: scanRoot, cache: cache), weight: weight / Double(urls.count))
                }
                emit()
            }
            let missing = total.unreadable - start.unreadable
            let value = Measurement(bytes: total.bytes - start.bytes, files: total.files - start.files,
                                    unreadable: missing, state: missing > 0 ? .partial : .complete)
            cache.store(value, for: item.url)
            return value
        }
        var result = listing
        // Useful user data first; the system subtree can be very large.
        let priority = ["Users": 0, "Applications": 1, "Library": 2, "System": 100]
        for item in listing.children.sorted(by: { (priority[$0.name] ?? 10) < (priority[$1.name] ?? 10) }) {
            try Task.checkCancellation()
            active = item; before = total
            // Distribute each directory's work share among its children as they
            // are discovered. This is monotonic coverage, not a known file count.
            let value = try walk(item, weight: 1 / Double(listing.children.count))
            var finished = item
            finished.bytes = value.bytes; finished.fileCount = value.files; finished.state = value.state
            if let index = result.children.firstIndex(where: { $0.id == item.id }) { result.children[index] = finished }
            emit(finished: finished)
        }
        try Task.checkCancellation()
        completedWork = 1
        emit(force: true, finished: result.children.first ?? listing)
        total.state = total.unreadable > 0 ? .partial : .complete
        if listing.state == .excluded { total.state = .excluded }
        else { cache.store(total, for: listing.url) }
        result.bytes = total.bytes; result.fileCount = total.files; result.state = total.state
        return ScanResult(root: result, unreadable: total.unreadable)
    }
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
