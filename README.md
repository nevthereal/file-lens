# File Lens

A fast, native macOS disk-space viewer. Every file and folder is a bubble whose area matches its size on disk, so you can see at a glance what's using your space and drill into it.

Built with SwiftUI and AppKit. No dependencies, no account, no network access, no telemetry.

<!-- Add a screenshot: save it as docs/screenshot.png and uncomment the line below. -->
<!-- ![File Lens](docs/screenshot.png) -->

## Features

- **Bubble map** of any drive or folder, with area proportional to size and colors by file type
- **Fast, parallel indexing** using bulk directory reads on several threads; browse while it runs
- **Instant reopen**: totals from the last index show right away while a fresh one runs
- **Accurate progress** bar and time remaining
- **Safe cleanup**: Move to Trash with confirmation, with system and home folders protected
- Quick Look, details panel, external drives, keyboard navigation

## Requirements

macOS 14 Sonoma or later. Apple silicon or Intel.

## Install

### Build it yourself (recommended)

Requires macOS 14+ and the Xcode command line tools with Swift 6 or later.

```sh
git clone https://github.com/nevthereal/file-lens.git
cd file-lens
./scripts/build-app.sh
ditto "dist/File Lens.app" "/Applications/File Lens.app"
open "/Applications/File Lens.app"
```

An app you build yourself isn't quarantined, so it opens without Gatekeeper warnings.

By default the app is signed ad-hoc. macOS ties Full Disk Access to the signature, which changes with every ad-hoc build, so you may have to re-enable access after rebuilding. To avoid that, sign with your own certificate (a free Apple Development certificate from Xcode works):

```sh
security find-identity -v -p codesigning          # list your identities
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

### Prebuilt download

[Releases](../../releases) include a zip of the app. It is **not signed or notarized**, so macOS blocks it the first time you open it. After the first attempt, go to **System Settings → Privacy & Security** and click **Open Anyway**, or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/File Lens.app"
```

Only do this if you trust the download; building from source lets you see exactly what you run.

### Full Disk Access

To measure protected folders (Mail, Messages, other apps' containers, and so on), File Lens needs Full Disk Access. The app asks on first launch if it doesn't have it:

1. Click **Open settings** (System Settings → Privacy & Security → Full Disk Access).
2. Click **+**, select File Lens, and turn it on.
3. Click **Relaunch**.

Without access, File Lens still works. Unreadable items are left out of totals, and the count of them is shown at the bottom of the window. macOS may ask again after you update to a new build.

## Usage

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

## Development

`swift run` starts the app directly, or open `Package.swift` in Xcode. `./scripts/build-app.sh` makes the app bundle in `dist/`; `VERSION`, `BUILD` and `SIGN_IDENTITY` environment variables set its version and signature.

```sh
swift test
```

Tests cover the bulk directory reader against FileManager, recursive totals, symlink and hard-link handling, focus and pause, in-place Trash accounting, saved indexes and stale totals, protected folders, grouped bubbles, file categories, navigation during indexing, Full Disk Access detection paths, progress/time estimates, drive selection and bubble packing.

### Releasing

Push a tag like `v1.1`. The release workflow runs the tests, builds the app with that version, and attaches a zip to a new GitHub release.

## Privacy

File Lens reads file metadata only (names, types, sizes, dates). It never reads file contents and never connects to the network. The only data it saves is folder size totals, in `~/Library/Caches/local.filelens.app`. Delete that folder to clear them.

## License

[MIT](LICENSE)
