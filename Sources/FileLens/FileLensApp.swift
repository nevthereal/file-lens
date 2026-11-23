import SwiftUI
import AppKit

@main
struct FileLensApp: App {
    @StateObject private var model = LensModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 560)
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Whole Drive") { model.scanDrive() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Open Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Rescan") { if let root = model.root { model.scan(root.url) } else { model.scanDrive() } }
                    .keyboardShortcut("r").disabled(model.scanning)
            }
            CommandGroup(after: .appSettings) {
                Button("Full Disk Access…") { model.showDiskAccess = true }
            }
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
                    fileList.frame(minWidth: 230, idealWidth: 280, maxWidth: 380)
                    visualization.frame(minWidth: 400)
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
        .sheet(isPresented: $model.showDiskAccess, onDismiss: { model.continueAfterAccessSetup() }) { diskAccessSheet }
        .alert("File Lens", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Full Disk Access…") { model.showDiskAccess = true }
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

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
            Button("Open…") { model.chooseFolder() }.keyboardShortcut("o")
            Button { if let root = model.root { model.scan(root.url) } else { model.scanDrive() } } label: {
                Image(systemName: "arrow.clockwise")
            }.disabled(model.scanning).help("Rescan (⌘R)")
            Button { model.showDiskAccess = true } label: { Image(systemName: "lock.open") }
                .help("Set up Full Disk Access")
        }
        .buttonStyle(.plain)
        .padding(.leading, 84).padding(.trailing, 20).frame(height: 54)
    }

    private var navigation: some View {
        HStack(spacing: 16) {
            Button { model.back() } label: { Image(systemName: "arrow.left") }.disabled(model.trail.count < 2)
            Button { model.forward() } label: { Image(systemName: "arrow.right") }.disabled(model.forwardTrail.isEmpty)
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        HStack(spacing: 0) {
                            Button { model.activate(item) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(.secondary).frame(width: 16)
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(item.sizeText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
                                    if item.isDirectory { Image(systemName: "chevron.right").font(.system(size: 10)).frame(width: 16) }
                                }.padding(.vertical, 12).padding(.trailing, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help(item.isDirectory ? "Open \(item.name)" : "Select \(item.name)")
                        }
                        .padding(.leading, 12)
                        .background(model.selection?.id == item.id ? Color.white.opacity(0.1) : .clear)
                        .contextMenu { itemMenu(item) }.disabled(model.trashing.contains(item.id))
                    }
                }
            }
            if model.items.isEmpty {
                Text(model.loading ? "Reading folder…" : "No items").foregroundStyle(.secondary).padding()
            }
        }.background(.black)
    }

    private var visualization: some View {
        VStack(spacing: 0) {
            if model.bubbleItems.isEmpty {
                Text(model.scanning ? "Measuring sizes… Browse folders while this runs." : "No sized items").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BubbleLayout(weights: model.bubbleItems.map { Double($0.bytes) }) {
                    ForEach(model.bubbleItems) { item in
                        BubbleView(item: item, selected: model.selection?.id == item.id) { model.activate(item) }
                            .contextMenu { itemMenu(item) }.disabled(model.trashing.contains(item.id))
                    }
                }.padding(12)
            }
            Text(model.scanning ? "sizes update as measured  /  ≥ means a partial total" : "click folders to explore  /  right-click for actions")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.bottom, 16)
        }
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
                    if status.phase == .running { Button("Stop") { model.cancel() }.buttonStyle(.plain).underline() }
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
            .help("Progress estimates recursive folder coverage. Time remaining is approximate and may change as folders are discovered. Opening a folder restarts the indicator for that folder. Inaccessible files are excluded.")
        }
    }

    private func indexingLabel(_ status: IndexingStatus) -> String {
        switch status.phase {
        case .idle: return "Ready"
        case .running:
            if model.loading { return "Reading \(status.scope)…" }
            let percent = Int((status.fraction ?? 0) * 100)
            return "Indexing \(status.scope) · ~\(percent)%"
        case .paused: return "Paused · \(status.scope)"
        case .failed: return "Indexing stopped · \(status.scope)"
        case .complete: return model.unreadable > 0 ? "Indexing finished · some items inaccessible" : "Indexed \(status.scope) · 100%"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.current?.children.count ?? 0) items")
            if model.bubbleItems.count < model.items.filter({ $0.bytes > 0 }).count { Text("/ largest 80 shown") }
            if model.unreadable > 0 {
                Button("/ \(model.unreadable) inaccessible") { model.showDiskAccess = true }
                    .buttonStyle(.plain).underline()
                    .help("Totals exclude unreadable items. Click to set up Full Disk Access.")
            }
            Spacer()
            if model.scanning { Text("\(model.visited.formatted()) entries checked") }
            Text("\(byteText(model.available)) free").fixedSize()
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(height: 34)
    }

    private var diskAccessSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ALLOW FULL DISK ACCESS").fontWeight(.semibold).tracking(2)
            Text("File Lens needs Full Disk Access to measure protected folders on your drive. Enable it in System Settings → Privacy & Security → Full Disk Access.")
            Text("Click +, select this app, and turn it on. Then quit and reopen File Lens to scan the whole drive with access.")
                .foregroundStyle(.secondary)
            Text(Bundle.main.bundlePath).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            Text("Unreadable items are excluded from totals. Some system files may remain inaccessible.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Button("Show app in Finder") { model.showAppInFinder() }
                Button("Open settings") { model.openDiskAccessSettings() }
                Spacer()
                Button("Continue") { model.continueAfterAccessSetup() }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 12, design: .monospaced)).lineSpacing(4)
            .padding(28).frame(width: 550).background(.black).foregroundStyle(.white).tint(.white)
    }

    @ViewBuilder private func itemMenu(_ item: DiskItem) -> some View {
        Button("Open in Finder") { model.reveal(item) }
        Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string) }
        Divider()
        Button("Move to Trash", role: .destructive) { Task { await model.moveToTrash(item) } }
            .disabled(!model.canTrash(item))
    }
}

struct BubbleView: View {
    let item: DiskItem
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            Button(action: action) {
                ZStack {
                    Circle().fill(.white.opacity(selected ? 0.14 : hovered ? 0.08 : 0.025))
                    Circle().strokeBorder(.white.opacity(selected || hovered ? 1 : 0.45), lineWidth: selected ? 2 : 1)
                    if diameter > 65 {
                        VStack(spacing: 5) {
                            if diameter > 120 {
                                Image(systemName: item.isDirectory ? "folder" : "doc").font(.system(size: 20, weight: .light)).padding(.bottom, 4)
                            }
                            Text(item.name).font(.system(size: min(13, diameter * 0.08), design: .monospaced))
                                .lineLimit(2).multilineTextAlignment(.center)
                            Text(item.sizeText).font(.system(size: min(11, diameter * 0.07), design: .monospaced)).foregroundStyle(.secondary)
                        }.padding(.horizontal, diameter * 0.13)
                    }
                }.contentShape(Circle())
            }.buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("\(item.name) — \(item.sizeText)\n" + (item.isDirectory ? "Click to explore. Right-click for actions." : "Click to select. Right-click for actions."))
                .accessibilityLabel("\(item.name), \(item.sizeText)")
                .accessibilityHint(item.isDirectory ? "Open folder. Context menu has Finder and Trash actions." : "Select file. Context menu has Finder and Trash actions.")
        }
    }
}
