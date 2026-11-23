import Darwin

/// Reads one directory with `getattrlistbulk(2)`, which returns names, types and
/// allocated sizes for many entries per system call instead of one `stat` per file.
enum DirectoryReader {
    struct HardLink: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    struct Contents: Sendable {
        var failed = false
        var subdirectories: [String] = []
        /// Bytes and count of non-directory entries with a single link.
        var fileBytes: Int64 = 0
        var fileCount: Int64 = 0
        /// Files with several hard links; the index counts each inode only once.
        var hardLinks: [(link: HardLink, bytes: Int64)] = []
        var unreadable: Int64 = 0
        var entries: Int { subdirectories.count + Int(fileCount) + hardLinks.count + Int(unreadable) }
    }

    // <sys/attr.h> constants, spelled out to avoid C macro import differences.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let typeDirectory: UInt32 = 2 // VDIR in <sys/vnode.h>

    static let bufferSize = 256 * 1024

    static func read(_ path: String, buffer: UnsafeMutableRawBufferPointer) -> Contents {
        var contents = Contents()
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { contents.failed = true; return contents }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnName | cmnDevID | cmnObjType | cmnFileID | cmnError
        request.fileattr = fileLinkCount | fileAllocSize

        while true {
            let count = getattrlistbulk(descriptor, &request, buffer.baseAddress, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                // A directory that fails part way is reported as unreadable.
                if contents.entries == 0 { contents.failed = true } else { contents.unreadable += 1 }
                return contents
            }
            if count == 0 { return contents }
            var entry = buffer.baseAddress!
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                var error: UInt32 = 0
                // ATTR_CMN_ERROR precedes the other common attributes.
                if returned.commonattr & cmnError != 0 { error = field.loadUnaligned(as: UInt32.self); field += 4 }
                var name: String?
                if returned.commonattr & cmnName != 0 {
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    field += MemoryLayout<attrreference_t>.size
                }
                var device: Int32 = 0
                if returned.commonattr & cmnDevID != 0 { device = field.loadUnaligned(as: Int32.self); field += 4 }
                var type: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 { type = field.loadUnaligned(as: UInt32.self); field += 4 }
                var inode: UInt64 = 0
                if returned.commonattr & cmnFileID != 0 { inode = field.loadUnaligned(as: UInt64.self); field += 8 }
                var links: UInt32 = 1
                if returned.fileattr & fileLinkCount != 0 { links = field.loadUnaligned(as: UInt32.self); field += 4 }
                var bytes: Int64 = 0
                if returned.fileattr & fileAllocSize != 0 { bytes = field.loadUnaligned(as: Int64.self); field += 8 }
                entry += length

                guard error == 0, let name else { contents.unreadable += 1; continue }
                if type == typeDirectory {
                    contents.subdirectories.append(name)
                } else if links > 1 {
                    contents.hardLinks.append((HardLink(device: device, inode: inode), bytes))
                } else {
                    contents.fileBytes += bytes
                    contents.fileCount += 1
                }
            }
        }
    }

    static func withBuffer<T>(_ body: (UnsafeMutableRawBufferPointer) -> T) -> T {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        return body(buffer)
    }
}
