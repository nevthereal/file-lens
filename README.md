# File Lens

A minimal black-and-white macOS disk viewer with monospaced type, built with SwiftUI and AppKit. No web view, dependencies, account, or network access.

## Run

Open `/Applications/File Lens.app` after installation (or `dist/File Lens.app` after a build). It opens Full Disk Access setup before scanning. After you continue, it starts at the entire startup drive (`/`). The drive menu in the toolbar lists the startup disk and connected external drives; choose one to scan it. The menu updates when drives are connected, disconnected, or renamed. **Open…** selects a specific folder.

On launch, the app asks you to set up Full Disk Access before it starts scanning. If access is already enabled, choose **Continue**. Use **Open settings**, then add File Lens with the **+** button under **Privacy & Security → Full Disk Access** and enable it. **Show app in Finder** locates the exact bundle to add. Quit and reopen File Lens after granting access. The lock button in the toolbar reopens these instructions at any time.

macOS requires you to grant this permission; the app cannot grant it to itself. File Lens is not sandboxed. Full Disk Access does not bypass Unix file permissions or System Integrity Protection. Until access is granted, it scans what is readable and reports omitted items. Rebuilding this locally signed app may require removing and adding it again in Full Disk Access.

- Bubble **area** is proportional to size on disk, for both files and folders.
- Click a folder bubble or list row to navigate into it. Clicking a file selects it.
- Right-click any item and choose **Open in Finder** to reveal it with the exact item highlighted.
- Right-click and choose **Move to Trash** to delete a file or folder recoverably. The view and sizes refresh after the move; failures leave the item in place and display an error.
- Use the back/forward buttons or path breadcrumbs to navigate.
- Filter by name, sort by size or name, and rescan with **⌘R**. **⌘O** opens another folder.
- Folder contents appear after a shallow directory read; you can browse without waiting for a whole-drive scan.
- Folder sizes are measured in the background and bubbles update as bytes are counted. Unknown sizes show **—**; **≥** marks a partial total. Completed zero-byte items are distinguished from unmeasured folders.
- Opening a folder cancels the previous measurement and prioritizes the visible folder. Completed subtree totals are cached for the session, so revisiting folders avoids repeating that work.
- The indexing indicator shows the active drive or folder, a progress bar, elapsed time, and an approximate time remaining after a short warmup. Progress estimates recursive folder coverage as directories are discovered; it is not a known percentage of all files or bytes. Uneven folder sizes can make the ETA change substantially. Opening a folder starts an indicator for that folder. Completed scans with unreadable entries are labeled as incomplete coverage.
- **Stop** pauses measurement and retains the partial view. Navigate to resume sizing, or use **⌘R** for a fresh scan. The cache is cleared for a fresh scan and is not persisted across launches.

macOS file metadata provides individual file sizes, not an instant recursive folder total. Folder totals still require reading descendants, but that work no longer blocks browsing. Only immediate children of visited folders are kept as UI nodes; the app no longer retains every file in the drive's tree.

The largest 80 nonempty items in the current folder appear as bubbles; the list includes every item. Very small bubbles may have no visible label; hover for their name and size. Empty files and folders remain in the list.

Folder sizes include all readable descendants, including hidden files. When scanning `/`, the backing mounts under `/System/Volumes`, other mounted drives under `/Volumes`, and virtual namespaces (`/dev`, `/Network`, `/.vol`) are excluded to avoid duplicate counting and traversing devices. Other drives can be scanned separately with **Open…**. Symbolic links are measured without following them, preventing cycles. Inaccessible items are reported and excluded from totals. To scan protected folders, allow the app access when macOS asks; broader access can be granted in **System Settings → Privacy & Security → Full Disk Access**, followed by quitting and reopening the app. File sizes use allocated bytes where available. Hard links and APFS clones can share storage, so per-path totals may differ from volume usage.

The app reads file metadata. Finder and Trash actions run only when you choose them from an item’s context menu. **Move to Trash** uses the native macOS Trash operation; it never falls back to permanent deletion.

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

Tests cover progress estimates, elapsed/remaining time, paused and completed indexing states, shallow listings, progressive totals, cancellation and subtree reuse, navigation during scans, stale-result rejection, symbolic-link cycles, empty and missing directories, whole-drive mount exclusions, drive selection, proportional bubble area, and nonoverlapping layout.
