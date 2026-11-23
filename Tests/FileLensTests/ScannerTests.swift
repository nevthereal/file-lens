import XCTest
@testable import FileLens

final class ScannerTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: root.appendingPathComponent("small.bin"))
        try Data(repeating: 51, count: 65536).write(to: root.appendingPathComponent("nested/large.bin"))
        return root
    }

    func testListingIsShallowAndFolderSizesAreUnknown() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = try DirectoryScanner.list(root, scanRoot: root, cache: MeasurementCache())
        let nested = try XCTUnwrap(listing.children.first { $0.name == "nested" })
        XCTAssertEqual(nested.state, .pending)
        XCTAssertEqual(nested.sizeText, "—")
        XCTAssertTrue(nested.children.isEmpty)
        XCTAssertEqual(nested.bytes, 0)
        XCTAssertEqual(listing.children.first { $0.name == "small.bin" }?.state, .complete)
    }

    func testTotalsSymlinkSafetyAndLazyChildren() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("nested/cycle"), withDestinationURL: root)
        let cache = MeasurementCache()
        let listing = try DirectoryScanner.list(root, scanRoot: root, cache: cache)
        let result = try DirectoryScanner.measure(listing, scanRoot: root, cache: cache) { _ in }
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertEqual(result.root.state, .complete)
        XCTAssertEqual(result.root.fileCount, 3)
        XCTAssertEqual(result.root.bytes, result.root.children.reduce(0) { $0 + $1.bytes })
        let nested = try XCTUnwrap(result.root.children.first { $0.name == "nested" })
        XCTAssertTrue(nested.children.isEmpty, "Measurement must not retain the recursive file tree")
        XCTAssertGreaterThan(nested.bytes, result.root.children.first { $0.name == "small.bin" }!.bytes)
        let nestedListing = try DirectoryScanner.list(nested.url, scanRoot: root, cache: cache)
        let link = try XCTUnwrap(nestedListing.children.first { $0.name == "cycle" })
        XCTAssertTrue(link.isSymbolicLink)
        XCTAssertFalse(link.isDirectory)
        XCTAssertEqual(nestedListing.bytes, nested.bytes)
        XCTAssertEqual(nestedListing.state, .complete)
    }

    func testPartialProgressIsPublishedBeforeAFolderFinishes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache()
        let listing = try DirectoryScanner.list(root, scanRoot: root, cache: cache)
        let snapshots = SnapshotCollector()
        let result = try DirectoryScanner.measure(listing, scanRoot: root, cache: cache, progressInterval: 0) { snapshots.append($0) }
        XCTAssertTrue(snapshots.values.contains { $0.children.contains { $0.state == .measuring && $0.bytes > 0 } })
        XCTAssertTrue(snapshots.values.allSatisfy { $0.total.bytes <= result.root.bytes })
        XCTAssertEqual(snapshots.values.last?.total.bytes, result.root.bytes)
        let fractions = snapshots.values.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(fractions.last, 1)
    }

    func testCancellationKeepsCompletedSubtreesAndDoesNotCachePartialRoot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache()
        let listing = try DirectoryScanner.list(root, scanRoot: root, cache: cache)
        let task = Task.detached {
            try DirectoryScanner.measure(listing, scanRoot: root, cache: cache, progressInterval: 0) { update in
                if update.children.contains(where: { $0.isDirectory && $0.state == .complete }) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertNil(cache.value(for: root))
        let nestedURL = try XCTUnwrap(listing.children.first { $0.name == "nested" }?.url)
        XCTAssertNotNil(cache.value(for: nestedURL))
        let refreshed = try DirectoryScanner.list(root, scanRoot: root, cache: cache)
        XCTAssertEqual(refreshed.children.first { $0.name == "nested" }?.state, .complete)
    }

    func testCachedSubtreeIsNotTraversedAgain() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache()
        let listing = try DirectoryScanner.list(root, scanRoot: root, cache: cache)
        let first = try DirectoryScanner.measure(listing, scanRoot: root, cache: cache) { _ in }
        let updates = SnapshotCollector()
        let second = try DirectoryScanner.measure(listing, scanRoot: root, cache: cache) { updates.append($0) }
        XCTAssertEqual(first.root.bytes, second.root.bytes)
        XCTAssertEqual(updates.values.last?.visited, listing.children.count)
    }

    func testEmptyFolderAndMissingRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache()
        let listing = try DirectoryScanner.list(root, scanRoot: root, cache: cache)
        let result = try DirectoryScanner.measure(listing, scanRoot: root, cache: cache) { _ in }
        XCTAssertEqual(result.root.bytes, 0)
        XCTAssertEqual(result.root.fileCount, 0)
        XCTAssertEqual(result.root.state, .complete)
        let missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try DirectoryScanner.list(missing, scanRoot: root, cache: cache))
    }

    func testWholeDriveAvoidsDuplicateAndVirtualMounts() {
        let root = URL(fileURLWithPath: "/")
        for path in ["/System/Volumes", "/Volumes", "/dev", "/Network", "/.vol"] {
            XCTAssertTrue(DirectoryScanner.skipsContents(of: URL(fileURLWithPath: path), scanRoot: root))
        }
        for path in ["/Users", "/Applications", "/Library", "/System"] {
            XCTAssertFalse(DirectoryScanner.skipsContents(of: URL(fileURLWithPath: path), scanRoot: root))
        }
        let external = URL(fileURLWithPath: "/Volumes/External")
        XCTAssertFalse(DirectoryScanner.skipsContents(of: external, scanRoot: external))
        let data = URL(fileURLWithPath: "/System/Volumes/Data")
        XCTAssertFalse(DirectoryScanner.skipsContents(of: data, scanRoot: data))
    }
}

private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ScanProgress] = []
    func append(_ snapshot: ScanProgress) { lock.lock(); defer { lock.unlock() }; snapshots.append(snapshot) }
    var values: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return snapshots }
}
