import Foundation

struct MountedDrive: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let external: Bool
}

enum DriveDiscovery {
    static func isExternal(local: Bool?, internalVolume: Bool?, removable: Bool?, ejectable: Bool?) -> Bool {
        local == true && (internalVolume == false || removable == true || ejectable == true)
    }

    static func mountedDrives() -> [MountedDrive] {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let rootName = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Macintosh HD"
        var drives = [MountedDrive(url: root, name: rootName, external: false)]
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: .skipHiddenVolumes) ?? []
        for url in volumes where url.path != "/" {
            guard let info = try? url.resourceValues(forKeys: keys),
                  isExternal(local: info.volumeIsLocal, internalVolume: info.volumeIsInternal, removable: info.volumeIsRemovable, ejectable: info.volumeIsEjectable) else { continue }
            let drive = MountedDrive(url: url, name: info.volumeName ?? url.lastPathComponent, external: true)
            if !drives.contains(where: { $0.id == drive.id }) { drives.append(drive) }
        }
        return [drives[0]] + drives.dropFirst().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func containing(_ url: URL, in drives: [MountedDrive]) -> MountedDrive? {
        let path = url.standardizedFileURL.path
        return drives.sorted { $0.url.path.count > $1.url.path.count }.first {
            let base = $0.url.standardizedFileURL.path
            return base == "/" || path == base || path.hasPrefix(base + "/")
        }
    }
}
