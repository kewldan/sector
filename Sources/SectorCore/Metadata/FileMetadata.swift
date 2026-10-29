import CoreServices
import Foundation

/// Lookups that need Spotlight or extra syscalls, done only for the few
/// items a screen actually shows.
public enum FileMetadata {
  /// When the user last opened the item, from Spotlight; nil if unknown.
  public static func lastUsedDate(_ url: URL) -> Date? {
    guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
    return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
  }

  /// When the item was added to its folder (Downloads age).
  public static func addedDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
  }

  /// Size of blocks owned by this file alone, i.e. what deleting it frees.
  /// Smaller than the allocated size for APFS clones.
  public static func privateSize(_ path: String) -> UInt64? {
    var list = attrlist()
    list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    list.commonattr = 0x8000_0000  // ATTR_CMN_RETURNED_ATTRS
    list.forkattr = 0x0000_0008  // ATTR_CMNEXT_PRIVATESIZE
    var buffer = [UInt8](repeating: 0, count: 64)
    let options = UInt32(FSOPT_NOFOLLOW) | 0x20  // FSOPT_ATTR_CMN_EXTENDED
    let rc = buffer.withUnsafeMutableBytes {
      getattrlist(path, &list, $0.baseAddress, $0.count, options)
    }
    guard rc == 0 else { return nil }
    return buffer.withUnsafeBytes { raw in
      // length (4) + returned attribute set (20), then the private size.
      let fork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
      guard fork & 0x8 != 0 else { return nil }
      return UInt64(clamping: raw.loadUnaligned(fromByteOffset: 24, as: Int64.self))
    }
  }
}

/// Full Disk Access, which macOS grants per app in System Settings.
public enum DiskAccess {
  /// Whether the app can read TCC-protected user data. Probes a few
  /// locations macOS always protects; any readable one means access.
  public static var hasFullAccess: Bool {
    let home = NSHomeDirectory()
    let probes = [
      home + "/Library/Safari",
      home + "/Library/Mail",
      home + "/Library/Messages",
      "/Library/Application Support/com.apple.TCC",
    ]
    let fm = FileManager.default
    for path in probes where fm.fileExists(atPath: path) {
      if (try? fm.contentsOfDirectory(atPath: path)) != nil { return true }
    }
    return false
  }

  /// Opens System Settings at Privacy & Security › Full Disk Access.
  public static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
