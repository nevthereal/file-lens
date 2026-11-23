import XCTest
@testable import FileLens

final class ModelTests: XCTestCase {
    @MainActor
    func testBrowseBeforeParentCompletesAndIgnoreCancelledResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 2, count: 8192).write(to: nested.appendingPathComponent("inner.bin"))
        try Data(repeating: 3, count: 16384).write(to: root.appendingPathComponent("outer.bin"))
        let model = LensModel(store: nil)
        model.scan(root)
        XCTAssertEqual(model.current?.id, root.path)
        XCTAssertTrue(model.scanning)
        XCTAssertTrue(model.loading)
        // Navigate before even the initial background listing has returned.
        model.activate(DiskItem.placeholder(nested))
        XCTAssertEqual(model.current?.id, nested.path)
        try await finish(model)
        XCTAssertEqual(model.trail.count, 2)
        XCTAssertEqual(model.current?.id, nested.path)
        XCTAssertEqual(model.items.map(\.name), ["inner.bin"])
        XCTAssertEqual(model.current?.state, .complete)
        model.back()
        XCTAssertEqual(model.current?.id, root.path)
        try await finish(model)
        XCTAssertEqual(Set(model.items.map(\.name)), Set(["nested", "outer.bin"]))
        XCTAssertEqual(model.current?.state, .complete)
        model.forward()
        try await finish(model)
        XCTAssertEqual(model.current?.id, nested.path)
        XCTAssertEqual(model.items.map(\.name), ["inner.bin"])
    }

    @MainActor
    func testSwitchingScanRootsCannotBeOverwrittenByPreviousScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LensModel(store: nil)
        model.scan(root)
        model.scan(second)
        try await finish(model)
        XCTAssertEqual(model.root?.id, second.path)
        XCTAssertEqual(model.trail.count, 1)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.current?.state, .complete)
    }

    @MainActor
    func testFileClickSelectsWithoutNavigating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("file.bin"))
        let model = LensModel(store: nil)
        model.scan(root)
        try await finish(model)
        let file = try XCTUnwrap(model.items.first)
        model.activate(file)
        XCTAssertEqual(model.selection?.id, file.id)
        XCTAssertEqual(model.trail.count, 1)
    }

    @MainActor
    func testTrashRefreshesFilesFoldersAndTotals() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("scan")
        let trash = base.appendingPathComponent("test-trash")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(repeating: 2, count: 8192).write(to: root.appendingPathComponent("folder/inner.bin"))
        try Data(repeating: 3, count: 16384).write(to: root.appendingPathComponent("outer.bin"))
        // Isolate the native file operation so these tests never touch the user's Trash.
        let model = LensModel(trashItem: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }, store: nil)
        model.scan(root)
        try await finish(model)
        XCTAssertFalse(model.canTrash(try XCTUnwrap(model.root)))
        for name in ["folder", "outer.bin"] {
            let item = try XCTUnwrap(model.items.first { $0.name == name })
            XCTAssertTrue(model.canTrash(item))
            let previous = try XCTUnwrap(model.current?.bytes)
            await model.moveToTrash(item)
            try await finish(model)
            XCTAssertFalse(model.items.contains { $0.id == item.id })
            XCTAssertEqual(model.current?.bytes, previous - item.bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(name).path))
        }
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.current?.bytes, 0)
    }

    @MainActor
    func testTrashFailureRetainsItemAndReportsError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("keep.bin"))
        let model = LensModel(trashItem: { _ in throw CocoaError(.fileWriteNoPermission) }, store: nil)
        model.scan(root)
        try await finish(model)
        let item = try XCTUnwrap(model.items.first)
        await model.moveToTrash(item)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.scanning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.scanning)
        XCTAssertTrue(model.items.contains { $0.id == item.id })
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.trashing.isEmpty)
    }

    @MainActor
    func testAccessSetupAppearsBeforeAnyScanWithoutAccess() {
        let model = LensModel(store: nil, accessProbe: { false })
        model.start()
        XCTAssertTrue(model.showDiskAccess)
        XCTAssertFalse(model.scanning)
        XCTAssertNil(model.root)
    }

    @MainActor
    func testAccessAlreadyGrantedSkipsSetupAndScans() {
        let model = LensModel(store: nil, accessProbe: { true })
        model.start()
        XCTAssertFalse(model.showDiskAccess)
        XCTAssertEqual(model.root?.id, "/")
        model.togglePause()
        XCTAssertEqual(model.indexing.phase, .paused)
    }

    @MainActor
    func testNavigationKeepsOneIndexRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4096).write(to: nested.appendingPathComponent("a.bin"))
        let model = LensModel(store: nil)
        model.scan(root)
        let started = model.indexing.startedAt
        model.activate(DiskItem.placeholder(nested))
        model.back()
        XCTAssertEqual(model.indexing.startedAt, started, "navigation must not restart indexing")
        try await finish(model)
        XCTAssertEqual(model.indexing.scope, root.lastPathComponent)
    }

    @MainActor
    func testProtectedAndGroupedItemsCannotBeTrashed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<(LensModel.bubbleLimit + 5) {
            try Data(repeating: 1, count: 4096 * (index + 1)).write(to: root.appendingPathComponent("f\(index).bin"))
        }
        let model = LensModel(store: nil)
        model.scan(root)
        try await finish(model)
        let bubbles = model.bubbleEntries
        XCTAssertEqual(bubbles.count, LensModel.bubbleLimit + 1)
        let other = try XCTUnwrap(bubbles.last?.item)
        XCTAssertEqual(other.aggregateCount, 5)
        XCTAssertEqual(bubbles.reduce(0) { $0 + Int64($1.weight) }, model.current?.bytes)
        XCTAssertFalse(model.canTrash(other))
        model.requestTrash(other)
        XCTAssertNil(model.pendingTrash)
        let file = try XCTUnwrap(model.items.first)
        model.requestTrash(file)
        XCTAssertEqual(model.pendingTrash?.id, file.id, "trash waits for confirmation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.id))
    }

    @MainActor
    func testRescanShowsPreviousTotalsWhileIndexing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        let storeDirectory = root.appendingPathComponent("store-outside").deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: storeDirectory) }
        try Data(repeating: 1, count: 4 << 20).write(to: nested.appendingPathComponent("big.bin"))
        let store = IndexStore(directory: storeDirectory)
        let first = LensModel(store: store)
        first.scan(root)
        try await finish(first)
        let expected = try XCTUnwrap(first.items.first { $0.name == "nested" }).bytes
        let deadline = ContinuousClock.now + .seconds(5)
        while store.load(root: root.path) == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let saved = try XCTUnwrap(store.load(root: root.path))
        XCTAssertEqual(saved.lookup()[nested.path]?.bytes, expected)
        let second = LensModel(store: store)
        second.scan(root, paused: true)
        XCTAssertNotNil(second.previousIndexDate)
        while second.loading { try await Task.sleep(for: .milliseconds(5)) }
        let stale = try XCTUnwrap(second.items.first { $0.name == "nested" })
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.bytes, expected)
        XCTAssertEqual(stale.sizeText.first, "≈")
        second.togglePause()
        try await finish(second)
        XCTAssertNil(second.previousIndexDate)
        XCTAssertEqual(second.items.first { $0.name == "nested" }?.bytes, expected)
    }

    @MainActor
    private func finish(_ model: LensModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.scanning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.scanning)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.indexing.phase, .complete)
        XCTAssertEqual(model.indexing.fraction, 1)
    }
}
