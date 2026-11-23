# File Lens

A minimal black-and-white macOS disk viewer with monospaced type, built with SwiftUI and AppKit. No web view, dependencies, account, or network access.

## Run

Open `/Applications/File Lens.app` (or `dist/File Lens.app` after a build). If Full Disk Access is already on, it starts indexing the startup drive immediately; otherwise it shows setup first. The sheet shows whether access is detected, opens the right Settings page, and has **Relaunch** (access applies to newly started processes). Rebuilding this locally signed app may require removing and re-adding it in Full Disk Access.

### Indexing

- One index covers the whole drive (or chosen folder) and keeps running while you browse. The folder you are viewing, and the folders leading to it, are read first; navigating never restarts the index.
- Directories are read with `getattrlistbulk` on several threads at once. Only folder totals are kept in memory, not individual files.
- Totals from the last finished index are saved in `~/Library/Caches/local.filelens.app/indexes` (last 8 drives/folders). On the next launch or rescan they appear immediately, marked **≈**, until the new index replaces them.
- Progress compares bytes counted with the last index's total; on a first run of a whole drive it uses the drive's used space, and for a new folder it estimates folder coverage. Time remaining follows from that.
- **Pause / Resume** (⇧⌘P) halts and continues the same index.
- Hard-linked files are counted once. APFS clones still count once per copy, so totals can exceed used space.
- When scanning `/`, `/System/Volumes`, `/Volumes`, `/dev`, `/Network` and `/.vol` are excluded. Symbolic links are not followed.

### Browsing

- Bubble **area** is proportional to size on disk. Colors mark folders, apps, images, video, audio, archives, code and documents (legend under the bubbles).
- The largest 60 items get their own bubble; everything smaller is combined into one dashed "smaller items" bubble, so the bubbles add up to the folder total.
- Bubbles hold still while the pointer is over them and animate to new sizes afterwards.
- **⇧⌘B** (or the ◎ button) shows each large folder's own contents inside its bubble.
- Click a folder to go into it. Apps and other packages behave like files; right-click → **Show Package Contents** to go inside.
- Selecting a file shows details (size, kind, dates, path) under the list.
- Keyboard: ↑/↓ select, Return/→ open, ← or ⌘[ back, ⌘] forward, ⌘↑ enclosing folder, Space Quick Look, ⌘⌫ move to Trash, ⌥⌘R show in Finder, ⌘R rescan, ⌘O open folder.

### Trash

**Move to Trash…** always asks for confirmation and shows the size. Top-level drive folders, system folders (`/System`, `/usr`, …), user home folders and standard home folders (Documents, Library, …) are protected. Totals are adjusted in place, without re-indexing. It uses the native macOS Trash and never deletes permanently.

## Build

Requires macOS 14+ and the Xcode command line tools with Swift 6+.

```sh
./scripts/build-app.sh
open "dist/File Lens.app"

# Install the app
ditto "dist/File Lens.app" "/Applications/File Lens.app"
open "/Applications/File Lens.app"
```

The build script renders the monochrome lens icon at every macOS icon size, makes a release app bundle, and signs it locally. The editable icon source is `scripts/make-icon.swift`. You can also open `Package.swift` in Xcode or run `swift run` for development.

```sh
swift test
```

Tests cover the bulk directory reader against FileManager, recursive totals, symlink and hard-link handling, focus and pause, in-place Trash accounting, saved indexes and stale totals, protected folders, grouped bubbles, file categories, navigation during indexing, Full Disk Access detection paths, progress/time estimates, drive selection and bubble packing.
