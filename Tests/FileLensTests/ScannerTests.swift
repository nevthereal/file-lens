import XCTest
@testable import FileLens

final class ScannerTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: root.appendingPathComponent("small.bin"))
        try Data(repeating: 51, count: 65536).write(to: root.appendingPathComponent("nested/large.bin"))
        try Data(repeating: 7, count: 20000).write(to: root.appendingPathComponent("nested/deeper/odd.bin"))
        return root
    }

    private func allocated(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }

    private func run(_ root: URL) throws -> IndexEngine {
        let engine = IndexEngine(root: root, workers: 4)
        engine.start()
        XCTAssertTrue(engine.waitUntilFinished(timeout: 10))
        return engine
    }

    func testBulkReaderMatchesFileManager() throws {
        // A real directory with many entries of different kinds.
        let directory = URL(fileURLWithPath: "/usr/bin")
        let contents = DirectoryReader.withBuffer { DirectoryReader.read(directory.path, buffer: $0) }
        XCTAssertFalse(contents.failed)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
        XCTAssertEqual(Set(contents.subdirectories), Set(folders.map(\.lastPathComponent)))
        XCTAssertEqual(contents.entries, urls.count)
    }

    func testTotalsMatchAllocatedSizesAndSymlinksAreNotFollowed() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("nested/cycle"), withDestinationURL: root)
        let engine = try run(root)
        let files = ["small.bin", "nested/large.bin", "nested/deeper/odd.bin"].map { allocated(root.appendingPathComponent($0)) }
        let status = try XCTUnwrap(engine.status(of: root.path))
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(status.files, 4, "three files plus the symbolic link itself")
        XCTAssertGreaterThanOrEqual(status.bytes, files.reduce(0, +))
        XCTAssertLessThan(status.bytes, files.reduce(0, +) + 64 * 1024, "a followed cycle would multiply the total")
        let deeper = try XCTUnwrap(engine.status(of: root.appendingPathComponent("nested/deeper").path))
        XCTAssertEqual(deeper.bytes, files[2])
        XCTAssertEqual(engine.progress().coverage, 1, accuracy: 0.000001)
    }

    func testHardLinksAreCountedOnce() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("nested/large.bin")
        let before = try XCTUnwrap(try run(root).status(of: root.path)).bytes
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("hardlink.bin"))
        let after = try XCTUnwrap(try run(root).status(of: root.path))
        XCTAssertEqual(after.bytes, before)
        XCTAssertEqual(after.files, 4)
    }

    func testFocusAndPauseStillFinishWithSameTotals() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try XCTUnwrap(try run(root).status(of: root.path))
        let engine = IndexEngine(root: root, workers: 3)
        engine.setPaused(true)
        engine.setFocus(root.appendingPathComponent("nested/deeper").path)
        engine.start()
        XCTAssertFalse(engine.waitUntilFinished(timeout: 0.2), "a paused index must not finish")
        XCTAssertEqual(engine.progress().directoriesRead, 0)
        engine.setPaused(false)
        XCTAssertTrue(engine.waitUntilFinished(timeout: 10))
        XCTAssertEqual(engine.status(of: root.path), reference)
    }

    func testRemovalAdjustsAncestorsWithoutRescan() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try run(root)
        let total = try XCTUnwrap(engine.status(of: root.path))
        let nested = root.appendingPathComponent("nested")
        let deeper = try XCTUnwrap(engine.status(of: nested.appendingPathComponent("deeper").path))
        engine.remove(path: nested.appendingPathComponent("deeper").path, isDirectory: true, bytes: deeper.bytes)
        XCTAssertNil(engine.status(of: nested.appendingPathComponent("deeper").path))
        XCTAssertEqual(engine.status(of: root.path)?.bytes, total.bytes - deeper.bytes)
        XCTAssertEqual(engine.status(of: root.path)?.files, total.files - deeper.files)
        let small = allocated(root.appendingPathComponent("small.bin"))
        engine.remove(path: root.appendingPathComponent("small.bin").path, isDirectory: false, bytes: small)
        XCTAssertEqual(engine.status(of: root.path)?.bytes, total.bytes - deeper.bytes - small)
    }

    func testEmptyAndMissingRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try run(root)
        XCTAssertEqual(empty.status(of: root.path), IndexEngine.Status(bytes: 0, files: 0, unreadable: 0, state: .complete))
        let missing = root.appendingPathComponent("missing")
        let failed = try run(missing)
        XCTAssertEqual(failed.status(of: missing.path)?.state, .inaccessible)
        XCTAssertThrowsError(try DirectoryScanner.list(missing, scanRoot: root))
    }

    func testListingIsShallowAndMarksPackages() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        let listing = try DirectoryScanner.list(root, scanRoot: root)
        let nested = try XCTUnwrap(listing.children.first { $0.name == "nested" })
        XCTAssertEqual(nested.state, .pending)
        XCTAssertTrue(nested.children.isEmpty)
        XCTAssertTrue(nested.isBrowsable)
        let app = try XCTUnwrap(listing.children.first { $0.name == "Tool.app" })
        XCTAssertTrue(app.isPackage)
        XCTAssertFalse(app.isBrowsable)
        XCTAssertEqual(app.category, .app)
        XCTAssertEqual(listing.children.first { $0.name == "small.bin" }?.state, .complete)
    }

    func testWholeDriveAvoidsDuplicateAndVirtualMounts() {
        for path in ["/System/Volumes", "/Volumes", "/dev", "/Network", "/.vol"] {
            XCTAssertTrue(IndexEngine.skipsContents(of: path, scanRoot: "/"))
        }
        for path in ["/Users", "/Applications", "/Library", "/System"] {
            XCTAssertFalse(IndexEngine.skipsContents(of: path, scanRoot: "/"))
        }
        XCTAssertFalse(IndexEngine.skipsContents(of: "/Volumes/External", scanRoot: "/Volumes/External"))
        XCTAssertFalse(IndexEngine.skipsContents(of: "/System/Volumes/Data", scanRoot: "/System/Volumes/Data"))
    }

    func testCategories() {
        func category(_ name: String) -> FileCategory { FileCategory.of(url: URL(fileURLWithPath: "/x/" + name), isDirectory: false, isPackage: false) }
        XCTAssertEqual(category("clip.mov"), .video)
        XCTAssertEqual(category("photo.JPG"), .image)
        XCTAssertEqual(category("song.mp3"), .audio)
        XCTAssertEqual(category("backup.zip"), .archive)
        XCTAssertEqual(category("main.swift"), .code)
        XCTAssertEqual(category("report.pdf"), .document)
        XCTAssertEqual(category("blob.qqq"), .other)
    }

    func testTrashPolicyProtectsSystemAndHomeFolders() {
        let home = URL(fileURLWithPath: "/Users/someone")
        for path in ["/", "/Applications", "/Users", "/Library", "/System/Library/Fonts", "/usr/local/bin",
                     "/Users/someone", "/Users/other", "/Users/someone/Documents", "/Users/someone/Library"] {
            XCTAssertTrue(TrashPolicy.isProtected(URL(fileURLWithPath: path), home: home), path)
        }
        for path in ["/Applications/Some.app", "/Users/someone/Documents/old.zip", "/Users/someone/Projects",
                     "/Users/someone/Library/Caches/thing", "/Volumes/Archive/folder"] {
            XCTAssertFalse(TrashPolicy.isProtected(URL(fileURLWithPath: path), home: home), path)
        }
    }

    func testIndexStoreRoundTripAndKeepsOnlyRecent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IndexStore(directory: directory, keep: 2)
        for root in ["/a", "/b", "/c"] {
            try store.save(SavedIndex(root: root, savedAt: Date(), duration: 3, paths: [root], bytes: [10], files: [1]))
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNil(store.load(root: "/a"))
        let loaded = try XCTUnwrap(store.load(root: "/c"))
        XCTAssertEqual(loaded.lookup()["/c"]?.bytes, 10)
    }
}
