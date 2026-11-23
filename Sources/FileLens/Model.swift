import SwiftUI
import AppKit

struct BubbleEntry: Identifiable {
    let item: DiskItem
    let weight: Double
    var id: String { item.id }
}

@MainActor
final class LensModel: ObservableObject {
    @Published var root: DiskItem?
    @Published var trail: [DiskItem] = []
    @Published var forwardTrail: [DiskItem] = []
    @Published var selection: DiskItem? { didSet { if quickLookURL != nil { quickLookURL = selection?.url } } }
    /// True while the index is actively reading (not paused, not finished).
    @Published private(set) var indexRunning = false
    @Published var loading = false
    @Published var indexing = IndexingStatus()
    @Published var trashing: Set<String> = []
    @Published var visited = 0
    @Published var unreadable = 0
    @Published var query = ""
    @Published var sortByName = false
    @Published var scanPath = ""
    @Published var errorMessage: String?
    @Published var errorOffersAccess = false
    @Published var capacity: Int64 = 0
    @Published var available: Int64 = 0
    @Published var showDiskAccess = false
    @Published private(set) var hasFullDiskAccess = false
    @Published var drives: [MountedDrive] = DriveDiscovery.mountedDrives()
    @Published var pendingTrash: DiskItem?
    @Published var quickLookURL: URL?
    @Published var showNested = false { didSet { if showNested { loadNested() } } }
    @Published private(set) var nested: [String: [DiskItem]] = [:]
    /// When totals from a previous index are on screen, the date of that index.
    @Published private(set) var previousIndexDate: Date?
    @Published private var frozenBubbles: FrozenBubbles?

    private struct FrozenBubbles {
        let folder: String
        let order: [String]
        let weights: [String: Double]
    }

    private var volumeObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var started = false
    private var engine: IndexEngine?
    private var saved: [String: (bytes: Int64, files: Int64)] = [:]
    private var savedRootBytes: Int64?
    private var ticker: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var listGeneration = UUID()
    private var nestedListings: [String: [DiskItem]] = [:]
    private var nestedLoading: Set<String> = []
    private let trashItem: @Sendable (URL) throws -> Void
    private let store: IndexStore?
    private let accessProbe: () -> Bool

    static let driveURL = URL(fileURLWithPath: "/", isDirectory: true)
    static let bubbleLimit = 60

    init(trashItem: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
         },
         store: IndexStore? = .shared,
         accessProbe: @escaping () -> Bool = LensModel.detectFullDiskAccess) {
        self.trashItem = trashItem
        self.store = store
        self.accessProbe = accessProbe
    }

    var scanning: Bool { indexRunning || loading }
    var current: DiskItem? { trail.last }
    var isPaused: Bool { indexing.phase == .paused }

    var selectedDrive: MountedDrive? {
        let url = root?.url ?? (scanPath.isEmpty ? Self.driveURL : URL(fileURLWithPath: scanPath))
        return DriveDiscovery.containing(url, in: drives)
    }

    var items: [DiskItem] {
        let all = current?.children ?? []
        let filtered = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted {
            if !sortByName && $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The largest items, plus one bubble that stands in for everything smaller,
    /// so bubble areas always add up to the folder's total.
    var bubbleEntries: [BubbleEntry] {
        let sized = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        var entries = sized.prefix(Self.bubbleLimit).map { BubbleEntry(item: $0, weight: Double($0.bytes)) }
        let rest = sized.dropFirst(Self.bubbleLimit)
        if let current, !rest.isEmpty {
            let bytes = rest.reduce(Int64(0)) { $0 + $1.bytes }
            let other = DiskItem(url: current.url.appendingPathComponent(".filelens-smaller-items"), isDirectory: false,
                                 isSymbolicLink: false, bytes: bytes, fileCount: rest.count, children: [],
                                 state: rest.contains { $0.state != .complete } ? .partial : .complete, aggregateCount: rest.count)
            entries.append(BubbleEntry(item: other, weight: Double(bytes)))
        }
        return entries
    }

    /// While the pointer is over the bubbles their sizes and positions hold still,
    /// so a bubble can't move out from under a click.
    var displayedBubbles: [BubbleEntry] {
        let live = bubbleEntries
        guard let frozen = frozenBubbles, frozen.folder == current?.id else { return live }
        var byID = Dictionary((current?.children ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in live where entry.item.aggregateCount > 0 { byID[entry.id] = entry.item }
        return frozen.order.compactMap { id in byID[id].map { BubbleEntry(item: $0, weight: frozen.weights[id] ?? 0) } }
    }

    func setBubblesHovered(_ hovered: Bool) {
        if hovered, let folder = current?.id {
            guard frozenBubbles?.folder != folder else { return }
            let entries = bubbleEntries
            frozenBubbles = FrozenBubbles(folder: folder, order: entries.map(\.id),
                                          weights: Dictionary(entries.map { ($0.id, $0.weight) }, uniquingKeysWith: { a, _ in a }))
        } else if !hovered {
            frozenBubbles = nil
        }
    }

    // MARK: Startup and access

    func start() {
        guard !started else { return }
        started = true
        refreshDrives()
        watchDrives()
        hasFullDiskAccess = accessProbe()
        if hasFullDiskAccess { scanDrive() } else { showDiskAccess = true }
    }

    func recheckAccess() {
        hasFullDiskAccess = accessProbe()
    }

    func continueAfterAccessSetup() {
        showDiskAccess = false
        if root == nil { scanDrive() }
    }

    /// macOS has no API to query Full Disk Access; these files are readable only with it.
    nonisolated static func detectFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let probes = ["/Library/Application Support/com.apple.TCC/TCC.db",
                      home + "/Library/Application Support/com.apple.TCC/TCC.db",
                      home + "/Library/Safari/Bookmarks.plist"]
        for path in probes {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 { close(descriptor); return true }
        }
        return false
    }

    func openDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Full Disk Access applies to newly started processes.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Drives

    func refreshDrives() {
        let previous = drives
        drives = DriveDiscovery.mountedDrives()
        let removed = previous.filter { old in !drives.contains(where: { $0.id == old.id }) }
        if let activeURL = root?.url, let disconnected = DriveDiscovery.containing(activeURL, in: removed) {
            stopEngine()
            root = nil
            trail = []
            forwardTrail = []
            selection = nil
            show(error: "\(disconnected.name) was disconnected. Select another drive to continue.", offersAccess: false)
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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        engine?.cancel()
    }

    // MARK: Scanning

    func scanDrive() { scan(Self.driveURL) }

    func rescan() {
        if let root { scan(root.url) } else { scanDrive() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to explore"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan folder"
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    /// `paused` starts the index without reading anything (used by tests).
    func scan(_ url: URL, paused: Bool = false) {
        let path = IndexEngine.normalize(url.path)
        // Totals from a finished index of the same root carry over to a rescan.
        var carried: [String: (bytes: Int64, files: Int64)]?
        if let engine, engine.rootPath == path, engine.progress().finished {
            carried = Dictionary(engine.completedEntries(minimumBytes: 0, alwaysWithinDepth: .max).map { ($0.path, ($0.bytes, $0.files)) },
                                 uniquingKeysWith: { a, _ in a })
        }
        stopEngine()
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        scanPath = path
        let placeholder = DiskItem.placeholder(rootURL)
        root = placeholder
        trail = [placeholder]
        forwardTrail = []
        selection = nil
        query = ""
        nested = [:]
        nestedListings = [:]
        frozenBubbles = nil
        let values = try? rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        capacity = Int64(values?.volumeTotalCapacity ?? 0)
        available = Int64(values?.volumeAvailableCapacity ?? 0)

        if let carried {
            saved = carried
            previousIndexDate = Date()
        } else if let previous = store?.load(root: path) {
            saved = previous.lookup()
            previousIndexDate = previous.savedAt
        } else {
            saved = [:]
            previousIndexDate = nil
        }
        savedRootBytes = saved[path]?.bytes

        let engine = IndexEngine(root: rootURL)
        self.engine = engine
        engine.setFocus(path)
        engine.setPaused(paused)
        engine.start()
        indexing.start(scope: placeholder.name)
        visited = 0
        unreadable = 0
        if paused {
            indexing.stop(.paused)
        } else {
            indexRunning = true
            startTicker()
        }
        loadCurrentFolder()
    }

    private func stopEngine() {
        engine?.cancel()
        engine = nil
        ticker?.cancel()
        ticker = nil
        if indexing.phase == .running { indexing.stop(.paused) }
        indexRunning = false
    }

    func togglePause() {
        guard let engine else { return }
        if indexing.phase == .running {
            engine.setPaused(true)
            indexing.stop(.paused)
            indexRunning = false
            ticker?.cancel()
            refreshSizes()
        } else if indexing.phase == .paused {
            engine.setPaused(false)
            indexing.resume()
            indexRunning = true
            startTicker()
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.refreshSizes()
                if !self.indexRunning { return }
            }
        }
    }

    private var isVolumeRoot: Bool { scanPath == "/" || drives.contains { $0.id == scanPath } }

    private func fraction(_ progress: IndexEngine.Progress) -> Double {
        if progress.finished { return 1 }
        // Bytes against a known total track real work far better than folder counts.
        if let expected = savedRootBytes, expected > 0 { return Double(progress.bytes) / Double(expected) }
        if isVolumeRoot, capacity > available { return Double(progress.bytes) / Double(capacity - available) }
        return progress.coverage
    }

    /// Pulls live totals from the index into the visible folder.
    func refreshSizes() {
        guard let engine else { return }
        // Read progress first: once it reports finished, every status read after it is final.
        let progress = engine.progress()
        if var item = current {
            let folders = item.children.lazy.filter(\.isDirectory).map(\.id)
            let statuses = engine.statuses(of: Array(folders) + [item.id])
            item.children = item.children.map { merge($0, statuses[$0.id]) }
            item = merge(item, statuses[item.id])
            setCurrent(item)
        }
        refreshNested(engine)
        visited = progress.directoriesRead
        unreadable = Int(progress.unreadable)
        if indexing.phase == .running { indexing.update(fraction(progress)) }
        if progress.finished && indexing.phase == .running { finish(engine) }
    }

    private func merge(_ item: DiskItem, _ status: IndexEngine.Status?) -> DiskItem {
        guard item.isDirectory, item.aggregateCount == 0 else { return item }
        var merged = item
        if let status, status.state != .measuring && status.state != .pending {
            merged.bytes = status.bytes; merged.fileCount = Int(status.files); merged.state = status.state
            return merged
        }
        if let previous = saved[item.id], (status?.bytes ?? 0) <= previous.bytes {
            merged.bytes = previous.bytes; merged.fileCount = Int(previous.files); merged.state = .stale
            return merged
        }
        if let status {
            merged.bytes = status.bytes; merged.fileCount = Int(status.files); merged.state = status.state
        } else if item.state != .excluded {
            merged.state = .pending
        }
        return merged
    }

    private func finish(_ engine: IndexEngine) {
        indexRunning = false
        indexing.stop(.complete)
        ticker?.cancel()
        previousIndexDate = nil
        guard let store else { return }
        let duration = indexing.elapsed(at: ProcessInfo.processInfo.systemUptime)
        let root = engine.rootPath
        Task.detached(priority: .utility) {
            // Keep large folders and the top levels; that is what gets browsed first.
            let entries = engine.completedEntries(minimumBytes: 1 << 20, alwaysWithinDepth: 2)
            try? store.save(SavedIndex(root: root, savedAt: Date(), duration: duration,
                                       paths: entries.map(\.path), bytes: entries.map(\.bytes), files: entries.map(\.files)))
        }
    }

    // MARK: Navigation

    private func setCurrent(_ item: DiskItem) {
        guard !trail.isEmpty else { return }
        trail[trail.count - 1] = item
        if trail.count == 1 { root = item }
    }

    private func loadCurrentFolder() {
        guard let url = current?.url else { return }
        let scope = URL(fileURLWithPath: scanPath)
        let token = UUID()
        listGeneration = token
        loading = true
        errorMessage = nil
        engine?.setFocus(url.path)
        refreshSizes()
        listTask?.cancel()
        listTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DirectoryScanner.list(url, scanRoot: scope) }
            }.value
            guard let self, self.listGeneration == token else { return }
            self.loading = false
            switch result {
            case .success(let listing):
                self.setCurrent(listing)
                self.refreshSizes()
                self.loadNested()
            case .failure(let error):
                if var item = self.current { item.state = .inaccessible; self.setCurrent(item) }
                self.show(error: error.localizedDescription, offersAccess: true)
            }
        }
    }

    func enter(_ item: DiskItem, intoPackage: Bool = false) {
        guard item.isDirectory, item.aggregateCount == 0, intoPackage || !item.isPackage else { selection = item; return }
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

    func up() { jump(to: trail.count - 2) }

    func jump(to index: Int) {
        guard index >= 0, index < trail.count - 1 else { return }
        forwardTrail = Array(trail.dropFirst(index + 1).reversed())
        trail = Array(trail.prefix(index + 1))
        navigated()
        loadCurrentFolder()
    }

    func activate(_ item: DiskItem) {
        if item.aggregateCount > 0 { sortByName = false; return }
        if item.isBrowsable { enter(item) } else { selection = item }
    }

    private func navigated() { selection = nil; query = ""; quickLookURL = nil }

    func reveal(_ item: DiskItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        let list = items
        guard !list.isEmpty else { return }
        let index = selection.flatMap { selected in list.firstIndex { $0.id == selected.id } }
        let next = index.map { max(0, min(list.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : list.count - 1)
        selection = list[next]
    }

    func openSelection() {
        guard let selection else { return }
        if selection.isBrowsable { enter(selection) } else { toggleQuickLook() }
    }

    func toggleQuickLook() {
        quickLookURL = quickLookURL == nil ? selection?.url : nil
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.rawValue
            let handled = MainActor.assumeIsolated {
                self?.handleKey(keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers)) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleKey(_ keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags) -> Bool {
        // Leave typing in the filter field and keys in dialogs alone.
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        if showDiskAccess || pendingTrash != nil || errorMessage != nil || current == nil { return false }
        let modifiers = flags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard modifiers.isEmpty else { return false }
        switch keyCode {
        case 49: toggleQuickLook()                 // space
        case 125: moveSelection(by: 1)              // down
        case 126: moveSelection(by: -1)             // up
        case 36, 76: openSelection()                // return, enter
        case 123: back()                            // left
        case 124: if selection?.isBrowsable == true { openSelection() } else { return false } // right
        default: return false
        }
        return true
    }

    // MARK: Trash

    func canTrash(_ item: DiskItem) -> Bool {
        item.aggregateCount == 0 && item.state != .excluded && !trashing.contains(item.id) &&
            current?.children.contains(where: { $0.id == item.id }) == true &&
            !drives.contains(where: { $0.id == item.id }) &&
            !TrashPolicy.isProtected(item.url)
    }

    /// Asks for confirmation before anything is moved.
    func requestTrash(_ item: DiskItem?) {
        guard let item, canTrash(item) else { return }
        pendingTrash = item
    }

    func moveToTrash(_ item: DiskItem) async {
        guard canTrash(item) else { return }
        let scopeID = root?.id
        trashing.insert(item.id)
        let operation = trashItem
        do {
            try await Task.detached(priority: .userInitiated) { try operation(item.url) }.value
            trashing.remove(item.id)
            guard root?.id == scopeID else { return }
            engine?.remove(path: item.id, isDirectory: item.isDirectory, bytes: item.bytes)
            forgetSaved(item)
            nestedListings[item.id] = nil
            for key in nestedListings.keys { nestedListings[key]?.removeAll { $0.id == item.id } }
            selection = nil
            forwardTrail = []
            var truncated = false
            if let index = trail.firstIndex(where: { $0.id == item.id }) {
                trail = Array(trail.prefix(index)); truncated = true
            }
            for index in trail.indices { trail[index].children.removeAll { $0.id == item.id } }
            root = trail.first
            let values = try? current?.url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            available = Int64(values?.volumeAvailableCapacity ?? 0)
            if truncated { loadCurrentFolder() } else { refreshSizes() }
        } catch {
            trashing.remove(item.id)
            show(error: "Couldn’t move “\(item.name)” to the Trash. \(error.localizedDescription)", offersAccess: false)
        }
    }

    private func forgetSaved(_ item: DiskItem) {
        guard !saved.isEmpty else { return }
        saved[item.id] = nil
        var path = (item.id as NSString).deletingLastPathComponent
        while path.hasPrefix(scanPath) {
            if var entry = saved[path] { entry.bytes -= item.bytes; saved[path] = entry }
            if path == scanPath || path == "/" { break }
            path = (path as NSString).deletingLastPathComponent
        }
        savedRootBytes = saved[scanPath]?.bytes
    }

    private func show(error: String, offersAccess: Bool) {
        errorOffersAccess = offersAccess
        errorMessage = error
    }

    // MARK: Nested bubbles

    private var nestedCandidates: [DiskItem] {
        Array(displayedBubbles.map(\.item).filter(\.isBrowsable).prefix(12))
    }

    private func loadNested() {
        guard showNested else { return }
        let scope = URL(fileURLWithPath: scanPath)
        for folder in nestedCandidates where nestedListings[folder.id] == nil && !nestedLoading.contains(folder.id) {
            nestedLoading.insert(folder.id)
            let url = folder.url
            Task { [weak self] in
                let listing = await Task.detached(priority: .utility) { try? DirectoryScanner.list(url, scanRoot: scope) }.value
                guard let self else { return }
                self.nestedLoading.remove(folder.id)
                self.nestedListings[folder.id] = listing?.children ?? []
                if let engine = self.engine { self.refreshNested(engine) }
            }
        }
    }

    private func refreshNested(_ engine: IndexEngine) {
        guard showNested else { if !nested.isEmpty { nested = [:] }; return }
        var result: [String: [DiskItem]] = [:]
        for folder in nestedCandidates {
            guard let children = nestedListings[folder.id] else { continue }
            let statuses = engine.statuses(of: children.filter(\.isDirectory).map(\.id))
            result[folder.id] = Array(children.map { merge($0, statuses[$0.id]) }
                .filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(24))
        }
        nested = result
        loadNested()
    }
}
