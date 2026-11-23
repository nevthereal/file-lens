import SwiftUI
import AppKit

@MainActor
final class LensModel: ObservableObject {
    @Published var root: DiskItem?
    @Published var trail: [DiskItem] = []
    @Published var forwardTrail: [DiskItem] = []
    @Published var selection: DiskItem?
    @Published var scanning = false
    @Published var loading = false
    @Published var indexing = IndexingStatus()
    @Published var trashing: Set<String> = []
    @Published var visited = 0
    @Published var unreadable = 0
    @Published var query = ""
    @Published var sortByName = false
    @Published var scanPath = ""
    @Published var errorMessage: String?
    @Published var capacity: Int64 = 0
    @Published var available: Int64 = 0
    @Published var showDiskAccess = false
    @Published var drives: [MountedDrive] = DriveDiscovery.mountedDrives()
    private var volumeObservers: [NSObjectProtocol] = []
    private var started = false

    var selectedDrive: MountedDrive? {
        let url = scanning ? URL(fileURLWithPath: scanPath) : (root?.url ?? Self.driveURL)
        return DriveDiscovery.containing(url, in: drives)
    }

    func refreshDrives() {
        let previous = drives
        drives = DriveDiscovery.mountedDrives()
        let removed = previous.filter { old in !drives.contains(where: { $0.id == old.id }) }
        let activeURL = scanning ? URL(fileURLWithPath: scanPath) : root?.url
        if let activeURL, let disconnected = DriveDiscovery.containing(activeURL, in: removed) {
            cancel()
            root = nil
            trail = []
            forwardTrail = []
            selection = nil
            errorMessage = "\(disconnected.name) was disconnected. Select another drive to continue."
        }
    }

    private func watchDrives() {
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDrives() }
            })
        }
    }

    deinit {
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    static let driveURL = URL(fileURLWithPath: "/", isDirectory: true)

    func start() {
        guard !started else { return }
        started = true
        refreshDrives()
        watchDrives()
        // Full Disk Access has no public request/status API. Present setup before
        // touching protected folders, and let the user continue explicitly.
        showDiskAccess = true
    }

    func continueAfterAccessSetup() {
        showDiskAccess = false
        if root == nil { scanDrive() }
    }

    func scanDrive() { scan(Self.driveURL) }

    func openDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private let trashItem: @Sendable (URL) throws -> Void

    init(trashItem: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.trashItem = trashItem
    }

    private var measurements = MeasurementCache()
    private var scanTask: Task<Void, Never>?
    private var worker: Task<ScanResult, Error>?
    private var generation = UUID()
    private var lastProgressSequence = 0

    var current: DiskItem? { trail.last }
    var items: [DiskItem] {
        let all = current?.children ?? []
        let filtered = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted {
            if !sortByName && $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var bubbleItems: [DiskItem] { Array(items.sorted { $0.bytes > $1.bytes }.filter { $0.bytes > 0 }.prefix(80)) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to explore"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan folder"
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    func scan(_ url: URL) {
        cancel()
        // A fresh cache isolates a rescan from writes by the cancelled worker.
        measurements = MeasurementCache()
        scanPath = url.path
        root = DiskItem.placeholder(url)
        trail = [root!]
        forwardTrail = []
        selection = nil
        query = ""
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        capacity = Int64(values?.volumeTotalCapacity ?? 0)
        available = Int64(values?.volumeAvailableCapacity ?? 0)
        loadCurrentFolder()
    }

    private func setCurrent(_ item: DiskItem) {
        guard !trail.isEmpty else { return }
        trail[trail.count - 1] = item
        if root?.id == item.id { root = item }
    }

    private func loadCurrentFolder() {
        cancel()
        guard let url = current?.url else { return }
        let scope = URL(fileURLWithPath: scanPath)
        let cache = measurements
        let token = UUID()
        generation = token
        scanning = true
        loading = true
        indexing.start(scope: current?.name ?? url.lastPathComponent)
        visited = 0
        lastProgressSequence = 0
        unreadable = 0
        errorMessage = nil
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            let listing = try DirectoryScanner.list(url, scanRoot: scope, cache: cache)
            await MainActor.run { [weak self] in
                guard let self, self.generation == token else { return }
                self.setCurrent(listing)
                self.loading = false
            }
            try Task.checkCancellation()
            return try DirectoryScanner.measure(listing, scanRoot: scope, cache: cache) { [weak self] update in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, update.sequence > self.lastProgressSequence, var item = self.current else { return }
                    self.lastProgressSequence = update.sequence
                    self.indexing.update(update.fraction)
                    let changes = Dictionary(uniqueKeysWithValues: update.children.map { ($0.id, $0) })
                    item.children = item.children.map { changes[$0.id] ?? $0 }
                    item.bytes = update.total.bytes
                    item.fileCount = update.total.files
                    item.state = .measuring
                    self.setCurrent(item)
                    self.visited = update.visited
                    self.unreadable = update.total.unreadable
                }
            }
        }
        self.worker = worker
        scanTask = Task { [weak self] in
            do {
                let result = try await worker.value
                guard let self, self.generation == token else { return }
                // Reject any queued progress delivery after completion.
                self.generation = UUID()
                self.setCurrent(result.root)
                self.unreadable = result.unreadable
                self.indexing.stop(.complete)
                self.loading = false
                self.scanning = false
            } catch is CancellationError {
                // Completed subtrees remain cached for the next navigation.
            } catch {
                guard let self, self.generation == token else { return }
                self.generation = UUID()
                if var item = self.current { item.state = .inaccessible; self.setCurrent(item) }
                self.errorMessage = error.localizedDescription
                self.indexing.stop(.failed)
                self.loading = false
                self.scanning = false
            }
        }
    }

    func cancel() {
        indexing.stop(.paused)
        generation = UUID()
        worker?.cancel()
        scanTask?.cancel()
        scanning = false
        loading = false
        if var item = current {
            if item.state == .measuring { item.state = item.bytes > 0 ? .partial : .pending }
            item.children = item.children.map { child in
                var child = child
                if child.state == .measuring { child.state = child.bytes > 0 ? .partial : .pending }
                return child
            }
            setCurrent(item)
        }
    }
    func enter(_ item: DiskItem) {
        guard item.isDirectory else { selection = item; return }
        trail.append(item)
        navigated()
        forwardTrail = []
        loadCurrentFolder()
    }
    func back() {
        guard trail.count > 1 else { return }
        forwardTrail.append(trail.removeLast())
        navigated()
        loadCurrentFolder()
    }
    func forward() {
        guard let next = forwardTrail.popLast() else { return }
        trail.append(next)
        navigated()
        loadCurrentFolder()
    }
    func jump(to index: Int) {
        guard index < trail.count - 1 else { return }
        forwardTrail = Array(trail.dropFirst(index + 1).reversed())
        trail = Array(trail.prefix(index + 1))
        navigated()
        loadCurrentFolder()
    }
    func activate(_ item: DiskItem) {
        if item.isDirectory { enter(item) }
        else { selection = item }
    }

    func canTrash(_ item: DiskItem) -> Bool {
        item.state != .excluded && !trashing.contains(item.id) &&
            current?.children.contains(where: { $0.id == item.id }) == true &&
            !drives.contains(where: { $0.id == item.id })
    }

    func moveToTrash(_ item: DiskItem) async {
        guard canTrash(item) else { return }
        let scopeID = root?.id
        cancel()
        trashing.insert(item.id)
        let operation = trashItem
        do {
            try await Task.detached(priority: .userInitiated) { try operation(item.url) }.value
            trashing.remove(item.id)
            // A drive switch already creates an independent cache and view.
            guard root?.id == scopeID else { return }
            cancel()
            measurements = MeasurementCache()
            // If navigation reached this folder while the move was running,
            // return to its parent rather than trying to list a trashed path.
            if let index = trail.firstIndex(where: { $0.id == item.id }) {
                trail = Array(trail.prefix(index))
            }
            forwardTrail = []
            selection = nil
            for index in trail.indices {
                trail[index].children.removeAll { $0.id == item.id }
                trail[index].state = .pending
            }
            if let first = trail.first { root = first }
            let values = try? current?.url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            available = Int64(values?.volumeAvailableCapacity ?? 0)
            loadCurrentFolder()
        } catch {
            trashing.remove(item.id)
            if root?.id == scopeID { loadCurrentFolder() }
            errorMessage = "Couldn’t move “\(item.name)” to Trash. \(error.localizedDescription)"
        }
    }

    private func navigated() { selection = nil; query = "" }
    func reveal(_ item: DiskItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
}
