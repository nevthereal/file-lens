import SwiftUI
import AppKit
import QuickLook

@main
struct FileLensApp: App {
    @StateObject private var model = LensModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 580)
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Whole Drive") { model.scanDrive() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Open Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Rescan") { model.rescan() }.keyboardShortcut("r").disabled(model.scanning)
                Button(model.isPaused ? "Resume Indexing" : "Pause Indexing") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.isPaused && !model.indexRunning)
            }
            CommandMenu("Go") {
                Button("Back") { model.back() }.keyboardShortcut("[").disabled(model.trail.count < 2)
                Button("Forward") { model.forward() }.keyboardShortcut("]").disabled(model.forwardTrail.isEmpty)
                Button("Enclosing Folder") { model.up() }.keyboardShortcut(.upArrow).disabled(model.trail.count < 2)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Quick Look (Space)") { model.toggleQuickLook() }.disabled(model.selection == nil)
                Button("Show in Finder") { if let item = model.selection { model.reveal(item) } }
                    .keyboardShortcut("r", modifiers: [.command, .option]).disabled(model.selection == nil)
                Button("Move to Trash…") { model.requestTrash(model.selection) }
                    .keyboardShortcut(.delete).disabled(model.selection.map { !model.canTrash($0) } ?? true)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Folder Contents in Bubbles", isOn: $model.showNested)
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) {
                Button("Full Disk Access…") { model.showDiskAccess = true }
            }
        }
    }
}

extension FileCategory {
    var color: Color {
        switch self {
        case .folder: return .white
        case .app: return Color(red: 0.66, green: 0.58, blue: 0.98)
        case .image: return Color(red: 0.38, green: 0.80, blue: 0.72)
        case .video: return Color(red: 0.95, green: 0.47, blue: 0.47)
        case .audio: return Color(red: 0.96, green: 0.73, blue: 0.36)
        case .archive: return Color(red: 0.80, green: 0.64, blue: 0.47)
        case .code: return Color(red: 0.46, green: 0.66, blue: 0.97)
        case .document: return Color(red: 0.88, green: 0.86, blue: 0.52)
        case .other: return Color(white: 0.55)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: LensModel
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.current != nil {
                navigation
                Divider()
                HSplitView {
                    fileList.frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
                    visualization.frame(minWidth: 420)
                }
                Divider()
                indexingIndicator
                footer
            } else {
                VStack(spacing: 18) {
                    Text("FILE LENS").font(.system(size: 24, weight: .medium, design: .monospaced))
                    Button("Scan whole drive") { model.scanDrive() }
                    Button("Open folder…") { model.chooseFolder() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
        .background(.black)
        .tint(.white)
        .onAppear { model.installKeyMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.recheckAccess() }
        .quickLookPreview($model.quickLookURL)
        .sheet(isPresented: $model.showDiskAccess, onDismiss: { model.continueAfterAccessSetup() }) { diskAccessSheet }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
                            presenting: model.pendingTrash) { item in
            Button("Move to Trash", role: .destructive) { Task { await model.moveToTrash(item) } }
            Button("Cancel", role: .cancel) { }
        } message: { item in
            Text("\(item.sizeText)\(item.isDirectory && item.fileCount > 0 ? " in \(item.fileCount.formatted()) files" : "") will be moved to the Trash. You can put it back until the Trash is emptied.\n\n\(item.url.path)")
        }
        .alert("File Lens", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.errorOffersAccess { Button("Full Disk Access…") { model.showDiskAccess = true } }
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var trashTitle: String { "Move “\(model.pendingTrash?.name ?? "")” to the Trash?" }

    private var header: some View {
        HStack(spacing: 18) {
            Text("FILE LENS").fontWeight(.semibold).tracking(2)
            Spacer()
            Menu {
                ForEach(model.drives) { drive in
                    Button { model.scan(drive.url) } label: {
                        Label(drive.name, systemImage: model.selectedDrive?.id == drive.id ? "checkmark" : (drive.external ? "externaldrive" : "internaldrive"))
                    }
                }
                Divider()
                Button("Refresh drives") { model.refreshDrives() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.selectedDrive?.external == true ? "externaldrive" : "internaldrive")
                    Text(model.selectedDrive?.name ?? "Drive").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
            }.menuStyle(.borderlessButton).fixedSize().help("Select a drive to scan")
            Button("Open…") { model.chooseFolder() }
            Button { model.showNested.toggle() } label: {
                Image(systemName: model.showNested ? "circle.circle.fill" : "circle.circle")
            }.help("Show folder contents inside bubbles (⇧⌘B)")
            Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.scanning).help("Rescan (⌘R)")
            Button { model.showDiskAccess = true } label: {
                Image(systemName: model.hasFullDiskAccess ? "lock.open" : "lock")
            }.help(model.hasFullDiskAccess ? "Full Disk Access is on" : "Set up Full Disk Access")
        }
        .buttonStyle(.plain)
        .padding(.leading, 84).padding(.trailing, 20).frame(height: 54)
    }

    private var navigation: some View {
        HStack(spacing: 16) {
            Button { model.back() } label: { Image(systemName: "arrow.left") }.disabled(model.trail.count < 2).help("Back (⌘[)")
            Button { model.forward() } label: { Image(systemName: "arrow.right") }.disabled(model.forwardTrail.isEmpty).help("Forward (⌘])")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Text("/").foregroundStyle(.secondary) }
                        Button(item.name) { model.jump(to: index) }
                            .foregroundStyle(index == model.trail.count - 1 ? .primary : .secondary)
                    }
                }
            }
            Text(model.current?.sizeText ?? "—").fixedSize()
        }.buttonStyle(.plain).padding(.horizontal, 20).frame(height: 44)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: $model.query).textFieldStyle(.plain)
                Menu {
                    Button("Size, largest first") { model.sortByName = false }
                    Button("Name") { model.sortByName = true }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().help("Sort items")
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in row(item).id(item.id) }
                    }
                }
                .onChange(of: model.selection?.id) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if model.items.isEmpty {
                Text(model.loading ? "Reading folder…" : "No items").foregroundStyle(.secondary).padding()
            }
            if let selection = model.selection {
                Divider()
                DetailsPanel(item: selection, model: model)
            }
        }.background(.black)
    }

    private func row(_ item: DiskItem) -> some View {
        Button { model.activate(item) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.category.symbol).foregroundStyle(item.category.color.opacity(item.category == .folder ? 0.6 : 0.9))
                    .frame(width: 16)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.sizeText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 10)).frame(width: 16).opacity(item.isBrowsable ? 1 : 0)
            }.padding(.vertical, 11).padding(.leading, 12).padding(.trailing, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(model.selection?.id == item.id ? Color.white.opacity(0.1) : .clear)
        .help(item.isBrowsable ? "Open \(item.name)" : "Select \(item.name)")
        .contextMenu { itemMenu(item) }
        .disabled(model.trashing.contains(item.id))
    }

    private var visualization: some View {
        VStack(spacing: 0) {
            let bubbles = model.displayedBubbles
            if bubbles.isEmpty {
                Text(model.scanning ? "Measuring sizes… Browse folders while this runs." : "No sized items")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BubbleLayout(weights: bubbles.map(\.weight)) {
                    ForEach(bubbles) { entry in
                        BubbleView(item: entry.item, selected: model.selection?.id == entry.id,
                                   nested: model.showNested ? model.nested[entry.id] : nil) { model.activate(entry.item) }
                            .contextMenu { if entry.item.aggregateCount == 0 { itemMenu(entry.item) } }
                            .disabled(model.trashing.contains(entry.id))
                    }
                }
                .animation(.easeInOut(duration: 0.45), value: bubbles.map(\.weight))
                .padding(12)
                .onHover { model.setBubblesHovered($0) }
            }
            legend(bubbles)
        }
    }

    private func legend(_ bubbles: [BubbleEntry]) -> some View {
        let present = Set(bubbles.filter { $0.item.aggregateCount == 0 }.map(\.item.category))
        return HStack(spacing: 14) {
            ForEach(FileCategory.allCases.filter(present.contains), id: \.self) { category in
                HStack(spacing: 5) {
                    Circle().fill(category.color).frame(width: 7, height: 7)
                    Text(category.label)
                }
            }
            if model.scanning {
                Text("≥ partial  /  ≈ last index").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        .padding(.bottom, 14).frame(height: 30)
    }

    private var indexingIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = model.indexing
            let now = ProcessInfo.processInfo.systemUptime
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(indexingLabel(status)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if status.phase == .running {
                        if let remaining = status.remaining(at: now) {
                            Text(IndexingStatus.remainingText(remaining))
                        } else { Text("Estimating time remaining…") }
                    }
                    Text("\(IndexingStatus.elapsedText(status.elapsed(at: now))) elapsed").foregroundStyle(.secondary)
                    if status.phase == .running || status.phase == .paused {
                        Button(status.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
                            .buttonStyle(.plain).underline().help("⇧⌘P")
                    }
                }
                if let fraction = status.fraction {
                    ProgressView(value: fraction).tint(.white)
                        .accessibilityLabel("Indexing \(status.scope)")
                } else if status.phase == .running {
                    ProgressView().progressViewStyle(.linear).tint(.white)
                        .accessibilityLabel("Discovering folders")
                } else { ProgressView(value: 0).tint(.white) }
            }
            .font(.system(size: 10, design: .monospaced)).monospacedDigit()
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            .help("One index covers the whole drive or folder and keeps running while you browse; the folder you are viewing is measured first. Progress compares bytes counted with the last index (or the drive's used space on a first run).")
        }
    }

    private func indexingLabel(_ status: IndexingStatus) -> String {
        switch status.phase {
        case .idle: return "Ready"
        case .running:
            let percent = Int((status.fraction ?? 0) * 100)
            var label = "Indexing \(status.scope) · ~\(percent)%"
            if let date = model.previousIndexDate {
                label += " · showing last index from \(date.formatted(.relative(presentation: .named)))"
            }
            return label
        case .paused: return "Paused · \(status.scope)"
        case .failed: return "Indexing stopped · \(status.scope)"
        case .complete: return model.unreadable > 0 ? "Indexed \(status.scope) · some items inaccessible" : "Indexed \(status.scope) · 100%"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.current?.children.count ?? 0) items")
            if let other = model.displayedBubbles.last?.item, other.aggregateCount > 0 {
                Text("/ \(other.aggregateCount) smaller grouped")
            }
            if model.unreadable > 0 {
                Button("/ \(model.unreadable) inaccessible") { model.showDiskAccess = true }
                    .buttonStyle(.plain).underline()
                    .help("Totals exclude unreadable items. Click to set up Full Disk Access.")
            }
            Spacer()
            if model.indexRunning { Text("\(model.visited.formatted()) folders read") }
            Text("\(byteText(model.available)) free").fixedSize()
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(height: 34)
    }

    private var diskAccessSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ALLOW FULL DISK ACCESS").fontWeight(.semibold).tracking(2)
            HStack(spacing: 8) {
                Circle().fill(model.hasFullDiskAccess ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(model.hasFullDiskAccess ? "Full Disk Access is on." : "Full Disk Access is not on yet.")
            }
            Text("File Lens needs Full Disk Access to measure protected folders on your drive. Enable it in System Settings → Privacy & Security → Full Disk Access.")
            Text("Click +, select this app, and turn it on. Then relaunch File Lens.")
                .foregroundStyle(.secondary)
            Text(Bundle.main.bundlePath).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            Text("Without it, unreadable items are left out of totals. Some system files stay inaccessible either way.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Button("Show app in Finder") { model.showAppInFinder() }
                Button("Open settings") { model.openDiskAccessSettings() }
                Button("Relaunch") { model.relaunch() }
                Spacer()
                Button("Continue") { model.continueAfterAccessSetup() }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 12, design: .monospaced)).lineSpacing(4)
            .padding(28).frame(width: 580).background(.black).foregroundStyle(.white).tint(.white)
            .onAppear { model.recheckAccess() }
    }

    @ViewBuilder private func itemMenu(_ item: DiskItem) -> some View {
        Button("Open in Finder") { model.reveal(item) }
        if item.isPackage { Button("Show Package Contents") { model.enter(item, intoPackage: true) } }
        Button("Show Details") { model.selection = item }
        Button("Quick Look") { model.selection = item; model.quickLookURL = item.url }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string) }
        Divider()
        if TrashPolicy.isProtected(item.url) {
            Button("Move to Trash… (protected folder)") { }.disabled(true)
        } else {
            Button("Move to Trash…", role: .destructive) { model.requestTrash(item) }.disabled(!model.canTrash(item))
        }
    }
}

struct DetailsPanel: View {
    let item: DiskItem
    @ObservedObject var model: LensModel
    @State private var info: Info?

    struct Info {
        var kind: String?
        var modified: Date?
        var created: Date?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.category.symbol).foregroundStyle(item.category.color)
                Text(item.name).fontWeight(.semibold).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button { model.selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            detail("Size", item.sizeText + (item.isDirectory && item.fileCount > 0 ? " · \(item.fileCount.formatted()) files" : ""))
            if let kind = info?.kind { detail("Kind", kind) }
            if let modified = info?.modified { detail("Modified", modified.formatted(date: .abbreviated, time: .shortened)) }
            if let created = info?.created { detail("Created", created.formatted(date: .abbreviated, time: .shortened)) }
            Text(item.url.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            HStack(spacing: 14) {
                Button("Quick Look") { model.quickLookURL = item.url }
                Button("Show in Finder") { model.reveal(item) }
            }.buttonStyle(.plain).underline().padding(.top, 2)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: item.id) {
            let values = try? item.url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .contentModificationDateKey, .creationDateKey])
            info = Info(kind: values?.localizedTypeDescription, modified: values?.contentModificationDate, created: values?.creationDate)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).lineLimit(1)
        }
    }
}

struct BubbleView: View {
    let item: DiskItem
    let selected: Bool
    let nested: [DiskItem]?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let color = item.aggregateCount > 0 ? Color(white: 0.6) : item.category.color
            Button(action: action) {
                ZStack {
                    Circle().fill(color.opacity(selected ? 0.22 : hovered ? 0.14 : 0.06))
                    if item.aggregateCount > 0 {
                        Circle().strokeBorder(color.opacity(hovered ? 0.9 : 0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    } else {
                        Circle().strokeBorder(color.opacity(selected || hovered ? 1 : 0.55), lineWidth: selected ? 2 : 1)
                    }
                    if let nested, !nested.isEmpty, diameter > 110 { NestedBubbles(items: nested, diameter: diameter) }
                    if diameter > 65 {
                        VStack(spacing: 5) {
                            if diameter > 120 && (nested?.isEmpty ?? true) {
                                Image(systemName: item.aggregateCount > 0 ? "ellipsis" : item.category.symbol)
                                    .font(.system(size: 20, weight: .light)).foregroundStyle(color).padding(.bottom, 4)
                            }
                            Text(item.name).font(.system(size: min(13, diameter * 0.08), design: .monospaced))
                                .lineLimit(2).multilineTextAlignment(.center)
                            Text(item.sizeText).font(.system(size: min(11, diameter * 0.07), design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, diameter * 0.13)
                        .padding(4)
                        .background(nested?.isEmpty == false ? Color.black.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }.contentShape(Circle())
            }.buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help(helpText)
                .accessibilityLabel("\(item.name), \(item.sizeText)")
                .accessibilityHint(item.isBrowsable ? "Open folder. Context menu has Finder and Trash actions." : "Select. Context menu has Finder and Trash actions.")
        }
    }

    private var helpText: String {
        if item.aggregateCount > 0 { return "\(item.name) — \(item.sizeText)\nToo small to draw separately; see the list." }
        return "\(item.name) — \(item.sizeText)\n" + (item.isBrowsable ? "Click to explore. Right-click for actions." : "Click to select. Right-click for actions.")
    }
}

/// A folder's own largest items, drawn inside its bubble.
struct NestedBubbles: View {
    let items: [DiskItem]
    let diameter: Double

    var body: some View {
        let packed = BubbleLayout(weights: items.map { Double($0.bytes) }).pack()
        Canvas { context, size in
            guard packed.bounds.width > 0, packed.bounds.height > 0 else { return }
            // The packing's bounding box must fit inside the circle: side = d / √2, with a margin.
            let side = diameter * 0.66
            let scale = min(side / packed.bounds.width, side / packed.bounds.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for (index, circle) in packed.circles.enumerated() {
                let radius = circle.radius * scale
                guard radius > 1.5 else { continue }
                let x = center.x + (circle.center.x - packed.bounds.midX) * scale
                let y = center.y + (circle.center.y - packed.bounds.midY) * scale
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                let color = items[index].category.color
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.08)))
                context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.45)), lineWidth: 0.75)
            }
        }
        .allowsHitTesting(false)
    }
}
