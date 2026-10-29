import Darwin

/// Request layout and parser for `getattrlistbulk(2)` entries.
///
/// Each returned entry starts with its length and the set of attributes
/// actually returned, followed by the attributes packed in bit order:
/// common (with `ATTR_CMN_ERROR` right after the returned set), then
/// directory, then file attributes. Values are 4-byte aligned, so 8-byte
/// fields are read unaligned.
enum BulkAttributes {
  // Common attributes (sys/attr.h).
  static let cmnName: UInt32 = 0x0000_0001
  static let cmnObjType: UInt32 = 0x0000_0008
  static let cmnModTime: UInt32 = 0x0000_0400
  static let cmnFlags: UInt32 = 0x0004_0000
  static let cmnFileID: UInt32 = 0x0200_0000
  static let cmnError: UInt32 = 0x2000_0000
  static let cmnReturnedAttrs: UInt32 = 0x8000_0000
  // Directory attributes.
  static let dirMountStatus: UInt32 = 0x0000_0004
  static let dirMountPoint: UInt32 = 0x0000_0001
  // File attributes.
  static let fileLinkCount: UInt32 = 0x0000_0001
  static let fileTotalSize: UInt32 = 0x0000_0002
  static let fileAllocSize: UInt32 = 0x0000_0004

  static let typeRegular: UInt32 = 1
  static let typeDirectory: UInt32 = 2
  static let typeSymlink: UInt32 = 5

  static let hiddenFlag: UInt32 = 0x0000_8000  // UF_HIDDEN

  static var request: attrlist {
    var list = attrlist()
    list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    list.commonattr =
      cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnModTime | cmnFlags | cmnFileID
    list.dirattr = dirMountStatus
    list.fileattr = fileLinkCount | fileTotalSize | fileAllocSize
    return list
  }

  struct Entry {
    var name: UnsafeBufferPointer<UInt8>
    var type: UInt32 = 0
    var modified: UInt32 = 0
    var flags: UInt32 = 0
    var fileID: UInt64 = 0
    var isMountPoint = false
    var linkCount: UInt32 = 1
    var logicalSize: UInt64 = 0
    var allocatedSize: UInt64 = 0

    var isHidden: Bool {
      flags & BulkAttributes.hiddenFlag != 0 || name.first == UInt8(ascii: ".")
    }
  }

  /// Parses one entry; nil if the kernel reported an error for it or it has
  /// no name.
  static func parse(_ start: UnsafeMutableRawPointer) -> Entry? {
    var p = UnsafeRawPointer(start) + 4
    let common = p.loadUnaligned(as: UInt32.self)
    let dir = p.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
    let file = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
    p += MemoryLayout<attribute_set_t>.size

    if common & cmnError != 0 {
      if p.loadUnaligned(as: UInt32.self) != 0 { return nil }
      p += 4
    }
    guard common & cmnName != 0 else { return nil }
    let nameOffset = Int(p.loadUnaligned(as: Int32.self))
    let nameLength = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
    let namePtr = (p + nameOffset).assumingMemoryBound(to: UInt8.self)
    // The reported length includes the trailing NUL.
    var entry = Entry(name: UnsafeBufferPointer(start: namePtr, count: max(0, nameLength - 1)))
    p += 8

    if common & cmnObjType != 0 {
      entry.type = p.loadUnaligned(as: UInt32.self)
      p += 4
    }
    if common & cmnModTime != 0 {
      entry.modified = UInt32(clamping: p.loadUnaligned(as: Int.self))
      p += MemoryLayout<timespec>.size
    }
    if common & cmnFlags != 0 {
      entry.flags = p.loadUnaligned(as: UInt32.self)
      p += 4
    }
    if common & cmnFileID != 0 {
      entry.fileID = p.loadUnaligned(as: UInt64.self)
      p += 8
    }
    if dir & dirMountStatus != 0 {
      entry.isMountPoint = p.loadUnaligned(as: UInt32.self) & dirMountPoint != 0
      p += 4
    }
    if file & fileLinkCount != 0 {
      entry.linkCount = p.loadUnaligned(as: UInt32.self)
      p += 4
    }
    if file & fileTotalSize != 0 {
      entry.logicalSize = UInt64(clamping: p.loadUnaligned(as: Int64.self))
      p += 8
    }
    if file & fileAllocSize != 0 {
      entry.allocatedSize = UInt64(clamping: p.loadUnaligned(as: Int64.self))
      p += 8
    }
    return entry
  }

  private static let packageSuffixes: [[UInt8]] = [
    ".app", ".bundle", ".framework", ".photoslibrary", ".fcpbundle", ".musiclibrary",
    ".tvlibrary", ".xcarchive", ".pvm", ".vmwarevm", ".utm", ".sparsebundle", ".rtfd",
    ".logicx", ".band", ".imovielibrary", ".plugin", ".kext", ".xpc", ".appex",
  ].map { Array($0.utf8) }

  static func isPackage(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
    for suffix in packageSuffixes where name.count > suffix.count {
      var match = true
      let offset = name.count - suffix.count
      for (i, ch) in suffix.enumerated() {
        // ASCII lower-casing is enough for these suffixes.
        var c = name[offset + i]
        if c >= 65 && c <= 90 { c += 32 }
        if c != ch {
          match = false
          break
        }
      }
      if match { return true }
    }
    return false
  }
}
