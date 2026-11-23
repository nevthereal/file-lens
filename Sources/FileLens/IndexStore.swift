import Foundation
import CryptoKit

/// Totals from the last finished index of a drive or folder, kept between launches.
/// They are shown (marked "≈") while a fresh index runs, and give the progress bar
/// an accurate denominator.
struct SavedIndex: Codable, Sendable {
    var root: String
    var savedAt: Date
    var duration: TimeInterval
    var paths: [String]
    var bytes: [Int64]
    var files: [Int64]

    func lookup() -> [String: (bytes: Int64, files: Int64)] {
        var result: [String: (bytes: Int64, files: Int64)] = [:]
        result.reserveCapacity(paths.count)
        for i in paths.indices { result[paths[i]] = (bytes[i], files[i]) }
        return result
    }
}

final class IndexStore: @unchecked Sendable {
    let directory: URL
    private let keep: Int

    init(directory: URL, keep: Int = 8) {
        self.directory = directory
        self.keep = keep
    }

    static let shared: IndexStore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return IndexStore(directory: caches.appendingPathComponent("local.filelens.app/indexes", isDirectory: true))
    }()

    private func file(for root: String) -> URL {
        let digest = SHA256.hash(data: Data(root.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    func load(root: String) -> SavedIndex? {
        guard let data = try? Data(contentsOf: file(for: root)),
              let saved = try? JSONDecoder().decode(SavedIndex.self, from: data),
              saved.root == root, saved.paths.count == saved.bytes.count, saved.bytes.count == saved.files.count else { return nil }
        return saved
    }

    func save(_ index: SavedIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: file(for: index.root), options: .atomic)
        prune()
    }

    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}
