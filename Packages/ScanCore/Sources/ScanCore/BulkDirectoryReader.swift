import Foundation
import Darwin

/// Thread-safe because directory listings may be prefetched concurrently.
final class PackageExtensionCache: @unchecked Sendable {
    private let values: NSCache<NSString, NSNumber>

    init() {
        values = NSCache()
        // A hostile tree may invent an extension per directory. Type answers
        // are an optimization, not something allowed to scale with entries.
        values.countLimit = 512
    }

    func isPackage(extension pathExtension: String, resolve: () -> Bool) -> Bool {
        let key = pathExtension as NSString
        if let cached = values.object(forKey: key) { return cached.boolValue }
        let resolved = resolve()
        values.setObject(NSNumber(value: resolved), forKey: key)
        return resolved
    }
}

/// macOS's packed bulk directory API, reduced to exactly `EntryMeta`.
///
/// Each record begins with `ATTR_CMN_RETURNED_ATTRS`, which drives parsing of
/// the remaining four-byte-aligned fields. Variable-length names are referenced
/// from the fixed portion by `attrreference_t`.
enum BulkDirectoryReader {
    private static let bufferBytes = 256 * 1_024
    private static let minimumRecordBytes = 36

    static func list(_ url: URL, isPackage: (String) -> Bool) -> [EntryMeta]? {
        // Reading the containing volume once replaces the same opaque
        // Foundation value on every child. A mounted child is the exception
        // and is refreshed below from its own URL.
        let parentVolumeObject = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?
            .volumeIdentifier as? NSObject

        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var requested = attrlist()
        requested.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        requested.commonattr = ATTR_CMN_RETURNED_ATTRS | mask(
            ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID
        )
        requested.dirattr = mask(ATTR_DIR_MOUNTSTATUS)
        requested.fileattr = mask(
            ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH | ATTR_FILE_DATAALLOCSIZE
        )

        let storage = UnsafeMutableRawBufferPointer.allocate(
            byteCount: bufferBytes,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { storage.deallocate() }

        var entries: [EntryMeta] = []
        while true {
            let count = getattrlistbulk(
                descriptor,
                &requested,
                storage.baseAddress,
                storage.count,
                0
            )
            guard count >= 0 else { return nil }
            if count == 0 { return entries }

            var recordOffset = 0
            for _ in 0..<count {
                guard let decoded = decode(
                    storage,
                    at: recordOffset,
                    parent: url,
                    parentVolumeObject: parentVolumeObject,
                    isPackage: isPackage
                ) else { return nil }
                entries.append(decoded.entry)
                recordOffset += decoded.length
                guard recordOffset <= storage.count else { return nil }
            }
        }
    }

    private static func decode(
        _ storage: UnsafeMutableRawBufferPointer,
        at recordOffset: Int,
        parent: URL,
        parentVolumeObject: NSObject?,
        isPackage: (String) -> Bool
    ) -> (entry: EntryMeta, length: Int)? {
        guard recordOffset >= 0,
              recordOffset + minimumRecordBytes <= storage.count,
              let base = storage.baseAddress else { return nil }

        let length = Int(base.loadUnaligned(fromByteOffset: recordOffset, as: UInt32.self))
        guard length >= minimumRecordBytes, recordOffset + length <= storage.count else { return nil }
        let recordEnd = recordOffset + length
        var offset = recordOffset + MemoryLayout<UInt32>.size

        guard offset + MemoryLayout<attribute_set_t>.size <= recordEnd else { return nil }
        let returned = base.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size

        func read<T>(_ type: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= recordEnd else { return nil }
            defer { offset += MemoryLayout<T>.size }
            return base.loadUnaligned(fromByteOffset: offset, as: T.self)
        }

        if has(returned.commonattr, ATTR_CMN_ERROR) {
            guard let entryError = read(UInt32.self), entryError == 0 else { return nil }
        }

        let nameReferenceOffset = offset
        guard has(returned.commonattr, ATTR_CMN_NAME),
              let nameReference = read(attrreference_t.self) else { return nil }
        let nameOffset = nameReferenceOffset + Int(nameReference.attr_dataoffset)
        let nameLength = Int(nameReference.attr_length)
        guard nameLength > 0,
              nameOffset >= recordOffset,
              nameOffset + nameLength <= recordEnd else { return nil }
        let nameBytes = UnsafeRawBufferPointer(start: base + nameOffset, count: nameLength)
        let terminator = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
        let name = String(decoding: nameBytes[..<terminator], as: UTF8.self)

        guard has(returned.commonattr, ATTR_CMN_OBJTYPE),
              let objectType = read(fsobj_type_t.self) else { return nil }
        let flags = has(returned.commonattr, ATTR_CMN_FLAGS) ? read(UInt32.self) : nil
        let fileID = has(returned.commonattr, ATTR_CMN_FILEID) ? read(UInt64.self) : nil
        let mountStatus = has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) ? read(UInt32.self) : nil
        let linkCount = has(returned.fileattr, ATTR_FILE_LINKCOUNT) ? read(UInt32.self) : nil
        let dataLength = has(returned.fileattr, ATTR_FILE_DATALENGTH) ? read(off_t.self) : nil
        let dataAllocated = has(returned.fileattr, ATTR_FILE_DATAALLOCSIZE) ? read(off_t.self) : nil

        let type = objectType
        let regular = type == VREG.rawValue
        let directory = type == VDIR.rawValue
        let symbolicLink = type == VLNK.rawValue

        var volumeObject = parentVolumeObject
        if directory,
           let mountStatus,
           mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 {
            let child = parent.appendingPathComponent(name, isDirectory: true)
            volumeObject = (try? child.resourceValues(forKeys: [.volumeIdentifierKey]))?
                .volumeIdentifier as? NSObject
        }
        let volumeIdentity = volumeObject.map(FileSystemIdentity.init)
        let identity = fileID.map { fileIdentity(fileID: $0, volumeObject: volumeObject) }
        let isDataless = flags.map { $0 & UInt32(bitPattern: SF_DATALESS) != 0 } ?? false
        let diskSize: Int64? = regular ? dataAllocated.map { Int64($0) } : nil
        let contentLength: Int64? = regular ? dataLength.map { Int64($0) } : nil
        let links: Int? = regular ? linkCount.map { Int($0) } : nil

        return (
            EntryMeta(
                name: name,
                isDirectory: directory,
                isRegularFile: regular,
                isSymbolicLink: symbolicLink,
                isPackage: directory && isPackage(name),
                diskSize: diskSize,
                contentLength: contentLength,
                linkCount: links,
                fileIdentity: identity,
                volumeIdentifier: volumeIdentity,
                isUbiquitousItem: isDataless,
                cloudDownloadingStatus: isDataless ? .notDownloaded : nil
            ),
            length
        )
    }

    /// APFS's opaque Foundation file identifier is the 64-bit inode followed
    /// by the opaque volume identifier. Reproducing that byte value keeps a
    /// bulk child comparable with a root read through URL resource values.
    static func fileIdentity(
        fileID: UInt64,
        volumeObject: NSObject?
    ) -> FileSystemIdentity {
        if let volumeData = volumeObject as? NSData {
            var nativeID = fileID
            let data = NSMutableData(bytes: &nativeID, length: MemoryLayout<UInt64>.size)
            data.append(volumeData.bytes, length: volumeData.length)
            return FileSystemIdentity(data)
        }
        return FileSystemIdentity("bulk:\(volumeObject?.hash ?? 0):\(fileID)")
    }

    private static func has(_ returned: attrgroup_t, _ requested: Int32) -> Bool {
        returned & mask(requested) != 0
    }

    private static func mask(_ value: Int32) -> attrgroup_t {
        UInt32(bitPattern: value)
    }
}
