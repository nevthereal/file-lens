import Foundation

/// One recursive index of a drive or folder, built by several worker threads.
///
/// Every directory gets a node with a parent link. Bytes are added to a node and all
/// of its ancestors as soon as a directory is read, so any folder shows a live partial
/// total. A node completes when it and all its subdirectories are read. Only directory
/// nodes are kept; files are summed and discarded.
///
/// The queue is depth-first and split in two: directories inside (or on the way to)
/// the folder being viewed are read before everything else. Navigating only changes
/// that focus; the index itself keeps running.
final class IndexEngine: @unchecked Sendable {
    struct Status: Sendable, Equatable {
        var bytes: Int64
        var files: Int64
        var unreadable: Int64
        var state: SizeState
    }

    struct Progress: Sendable {
        var bytes: Int64
        var files: Int64
        var unreadable: Int64
        var directoriesRead: Int
        /// Monotonic share of discovered work that is done, 0...1.
        var coverage: Double
        var finished: Bool
        var paused: Bool
    }

    struct Entry: Sendable {
        let path: String
        let bytes: Int64
        let files: Int64
        let depth: Int
    }

    private struct Node {
        var parent: Int32
        var depth: UInt16
        var weight: Double
        var bytes: Int64 = 0
        var files: Int64 = 0
        var unreadable: Int64 = 0
        var pending: Int32 = 0
        var read = false
        var complete = false
        var removed = false
        var excluded = false
        var failed = false
    }

    let root: URL
    let rootPath: String
    private let condition = NSCondition()
    private var nodes: [Node] = []
    private var paths: [String] = []
    private var index: [String: Int32] = [:]
    private var focusQueue: [Int32] = []
    private var queue: [Int32] = []
    private var focus: String?
    private var inFlight = 0
    private var cancelled = false
    private var paused = false
    private var finished = false
    private var started = false
    private var coverage = 0.0
    private var directoriesRead = 0
    private var seenLinks = Set<DirectoryReader.HardLink>()
    private let workers: Int

    init(root: URL, workers: Int = max(2, min(12, ProcessInfo.processInfo.activeProcessorCount))) {
        self.root = root
        rootPath = Self.normalize(root.path)
        self.workers = workers
        nodes.append(Node(parent: -1, depth: 0, weight: 1))
        paths.append(rootPath)
        index[rootPath] = 0
        queue.append(0)
    }

    static func normalize(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.isEmpty ? "/" : standard
    }

    private static let wholeDriveExclusions: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/Network", "/.vol"]

    /// Other volumes and virtual file systems under `/` would be counted twice or never end.
    static func skipsContents(of path: String, scanRoot: String) -> Bool {
        scanRoot == "/" && wholeDriveExclusions.contains(path)
    }

    // MARK: Control

    func start() {
        condition.lock()
        guard !started else { condition.unlock(); return }
        started = true
        condition.unlock()
        for _ in 0..<workers {
            let thread = Thread { [self] in DirectoryReader.withBuffer { work(buffer: $0) } }
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    func cancel() {
        condition.lock(); cancelled = true; condition.broadcast(); condition.unlock()
    }

    func setPaused(_ value: Bool) {
        condition.lock(); paused = value; condition.broadcast(); condition.unlock()
    }

    /// Reorders queued work so `path`, and the directories leading to it, come first.
    func setFocus(_ path: String?) {
        condition.lock(); defer { condition.unlock() }
        focus = path.map(Self.normalize)
        let all = queue + focusQueue
        queue = []; focusQueue = []
        for id in all {
            if isFocused(paths[Int(id)]) { focusQueue.append(id) } else { queue.append(id) }
        }
    }

    private func isFocused(_ path: String) -> Bool {
        guard let focus else { return false }
        if path == focus || focus == "/" { return true }
        return path.hasPrefix(focus + "/") || focus.hasPrefix(path == "/" ? "/" : path + "/")
    }

    // MARK: Workers

    private func work(buffer: UnsafeMutableRawBufferPointer) {
        while true {
            condition.lock()
            var next: Int32?
            while next == nil {
                if cancelled || finished { condition.unlock(); return }
                if !paused, let id = focusQueue.popLast() ?? queue.popLast() {
                    next = id
                } else if !paused && inFlight == 0 {
                    finished = true
                    condition.broadcast()
                    condition.unlock()
                    return
                } else {
                    condition.wait()
                }
            }
            let id = next!
            if isRemoved(id) { condition.unlock(); continue }
            inFlight += 1
            let path = paths[Int(id)]
            condition.unlock()

            let contents = autoreleasepool { DirectoryReader.read(path, buffer: buffer) }

            condition.lock()
            apply(contents, to: id, path: path)
            inFlight -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    private func isRemoved(_ id: Int32) -> Bool {
        var current = id
        while current >= 0 {
            if nodes[Int(current)].removed { return true }
            current = nodes[Int(current)].parent
        }
        return false
    }

    /// Adds to a node and its ancestors, stopping at a removed subtree.
    private func add(_ id: Int32, bytes: Int64, files: Int64, unreadable: Int64) {
        var current = id
        while current >= 0 {
            let i = Int(current)
            nodes[i].bytes += bytes; nodes[i].files += files; nodes[i].unreadable += unreadable
            if nodes[i].removed { return }
            current = nodes[i].parent
        }
    }

    private func complete(_ id: Int32) {
        var current = id
        while current >= 0 {
            let i = Int(current)
            guard !nodes[i].complete else { return }
            nodes[i].complete = true
            if nodes[i].removed { return }
            let parent = nodes[i].parent
            guard parent >= 0 else { return }
            nodes[Int(parent)].pending -= 1
            guard nodes[Int(parent)].read && nodes[Int(parent)].pending == 0 else { return }
            current = parent
        }
    }

    private func apply(_ contents: DirectoryReader.Contents, to id: Int32, path: String) {
        let i = Int(id)
        directoriesRead += 1
        nodes[i].read = true
        let weight = nodes[i].weight
        if contents.failed {
            nodes[i].failed = true
            add(id, bytes: 0, files: 0, unreadable: 1)
            coverage += weight
            complete(id)
            return
        }
        var bytes = contents.fileBytes
        var files = contents.fileCount
        for (link, size) in contents.hardLinks {
            files += 1
            if seenLinks.insert(link).inserted { bytes += size }
        }
        add(id, bytes: bytes, files: files, unreadable: contents.unreadable)

        let entries = contents.entries
        guard entries > 0 else { coverage += weight; complete(id); return }
        let share = weight / Double(entries)
        var settled = entries - contents.subdirectories.count
        let depth = nodes[i].depth &+ 1
        var children: [(id: Int32, rank: Int)] = []
        for name in contents.subdirectories {
            let childPath = path == "/" ? "/" + name : path + "/" + name
            let child = Int32(nodes.count)
            var node = Node(parent: id, depth: depth, weight: share)
            if Self.skipsContents(of: childPath, scanRoot: rootPath) {
                node.read = true; node.complete = true; node.excluded = true
                settled += 1
            } else {
                nodes[i].pending += 1
            }
            nodes.append(node)
            paths.append(childPath)
            index[childPath] = child
            if !node.excluded { children.append((child, Self.rank(childPath))) }
        }
        coverage += share * Double(settled)
        // Stacks pop from the end, so push the most useful folders last.
        for child in children.sorted(by: { $0.rank > $1.rank }) {
            if isFocused(paths[Int(child.id)]) { focusQueue.append(child.id) } else { queue.append(child.id) }
        }
        if nodes[i].pending == 0 { complete(id) }
    }

    /// User data first; the sealed system volume last.
    private static func rank(_ path: String) -> Int {
        switch path {
        case "/Users": return 0
        case "/Applications": return 1
        case "/Library": return 2
        case "/System": return 100
        default: return 10
        }
    }

    // MARK: Queries

    func status(of path: String) -> Status? {
        condition.lock(); defer { condition.unlock() }
        return statusLocked(Self.normalize(path))
    }

    func statuses(of paths: [String]) -> [String: Status] {
        condition.lock(); defer { condition.unlock() }
        var result: [String: Status] = [:]
        for path in paths { if let status = statusLocked(path) { result[path] = status } }
        return result
    }

    private func statusLocked(_ path: String) -> Status? {
        guard let id = index[path], !isRemoved(id) else { return nil }
        let node = nodes[Int(id)]
        let state: SizeState
        if node.excluded { state = .excluded }
        else if node.failed { state = .inaccessible }
        else if node.complete { state = node.unreadable > 0 ? .partial : .complete }
        else if node.read { state = .measuring }
        else { state = .pending }
        return Status(bytes: node.bytes, files: node.files, unreadable: node.unreadable, state: state)
    }

    func progress() -> Progress {
        condition.lock(); defer { condition.unlock() }
        let root = nodes[0]
        return Progress(bytes: root.bytes, files: root.files, unreadable: root.unreadable,
                        directoriesRead: directoriesRead, coverage: min(1, coverage),
                        finished: finished, paused: paused)
    }

    /// Accounts for an item moved to the Trash without re-reading anything.
    func remove(path: String, isDirectory: Bool, bytes: Int64) {
        condition.lock(); defer { condition.unlock() }
        let path = Self.normalize(path)
        if isDirectory, let id = index[path] {
            guard !isRemoved(id) else { return }
            let node = nodes[Int(id)]
            if node.parent >= 0 { add(node.parent, bytes: -node.bytes, files: -node.files, unreadable: -node.unreadable) }
            nodes[Int(id)].removed = true
            // An unfinished subtree must not hold its parent open.
            if !node.complete, node.parent >= 0 {
                let parent = Int(node.parent)
                nodes[parent].pending -= 1
                if nodes[parent].read && nodes[parent].pending == 0 { complete(node.parent) }
            }
        } else if !isDirectory, let parent = index[(path as NSString).deletingLastPathComponent], nodes[Int(parent)].read {
            add(parent, bytes: -bytes, files: -1, unreadable: 0)
        }
    }

    /// Finished directories worth remembering between launches.
    func completedEntries(minimumBytes: Int64, alwaysWithinDepth: Int) -> [Entry] {
        condition.lock(); defer { condition.unlock() }
        var result: [Entry] = []
        for (i, node) in nodes.enumerated() where node.complete && !node.excluded && !node.failed && !node.removed {
            guard node.bytes >= minimumBytes || Int(node.depth) <= alwaysWithinDepth else { continue }
            guard !isRemoved(Int32(i)) else { continue }
            result.append(Entry(path: paths[i], bytes: node.bytes, files: node.files, depth: Int(node.depth)))
        }
        return result
    }

    /// Blocks until the index finishes; for tests and tools.
    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !finished { if !condition.wait(until: deadline) { return finished } }
        return true
    }
}
