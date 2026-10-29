import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Broad file kind of a duplicate, for the tile color and thumbnail layout.
enum DuplicateKind {
  case photo, video, audio, pdf, document, archive, other

  init(path: String) {
    let ext = (path as NSString).pathExtension
    guard let type = UTType(filenameExtension: ext) else {
      self = .other
      return
    }
    if type.conforms(to: .image) {
      self = .photo
    } else if type.conforms(to: .movie) || type.conforms(to: .video) {
      self = .video
    } else if type.conforms(to: .audio) {
      self = .audio
    } else if type.conforms(to: .pdf) {
      self = .pdf
    } else if type.conforms(to: .archive) || type.conforms(to: .diskImage)
      || ["pkg", "mpkg", "dmg", "iso"].contains(ext.lowercased())
    {
      self = .archive
    } else if type.conforms(to: .content) || type.conforms(to: .text)
      || type.conforms(to: .package)
    {
      self = .document
    } else {
      self = .other
    }
  }

  /// Media fill the whole tile; documents sit on it as a page.
  var isMedia: Bool { self == .photo || self == .video }

  /// Tile gradient, top to bottom (from the mock's sample palette).
  var gradient: [Color] {
    switch self {
    case .photo: return [Color(hex: 0x7DC4FF), Color(hex: 0x3D8BFF)]
    case .video: return [Color(hex: 0xD3A6F2), Color(hex: 0x8E44D6)]
    case .audio: return [Color(hex: 0xFFB3C6), Color(hex: 0xFF2D55)]
    case .pdf: return [Color(hex: 0xFFA3A9), Color(hex: 0xE5243B)]
    case .document: return [Color(hex: 0xFFD68A), Color(hex: 0xFF9F1A)]
    case .archive: return [Color(hex: 0xD6D6DB), Color(hex: 0x9A9AA0)]
    case .other: return [Color(hex: 0x9BE3B0), Color(hex: 0x2FA956)]
    }
  }

  var background: LinearGradient {
    LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
  }
}

/// QuickLook thumbnails, generated off the main actor and cached.
@MainActor
final class ThumbnailCache {
  static let shared = ThumbnailCache()

  private let cache = NSCache<NSString, NSImage>()
  private var pending: [String: Task<NSImage?, Never>] = [:]

  init() { cache.countLimit = 600 }

  func cached(_ path: String, side: CGFloat) -> NSImage? {
    cache.object(forKey: key(path, side) as NSString)
  }

  func image(for path: String, side: CGFloat, scale: CGFloat) async -> NSImage? {
    let key = key(path, side)
    if let image = cache.object(forKey: key as NSString) { return image }
    if let task = pending[key] { return await task.value }
    let task = Task<NSImage?, Never> {
      guard let cg = await Self.generate(path: path, side: side, scale: scale)?.image else {
        return nil
      }
      return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale,
                                               height: CGFloat(cg.height) / scale))
    }
    pending[key] = task
    let image = await task.value
    pending[key] = nil
    if let image { cache.setObject(image, forKey: key as NSString) }
    return image
  }

  private func key(_ path: String, _ side: CGFloat) -> String { "\(Int(side))|\(path)" }

  private struct CGBox: @unchecked Sendable { var image: CGImage }

  nonisolated private static func generate(
    path: String, side: CGFloat, scale: CGFloat
  ) async -> CGBox? {
    let request = QLThumbnailGenerator.Request(
      fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side), scale: scale,
      representationTypes: .all)
    return await withCheckedContinuation { continuation in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
        continuation.resume(returning: rep.map { CGBox(image: $0.cgImage) })
      }
    }
  }
}

/// Thumbnail of a file that fades in once QuickLook delivers it.
struct FileThumbnail: View {
  var path: String
  var side: CGFloat
  var contentMode: ContentMode = .fill

  @Environment(\.displayScale) private var scale
  @State private var image: NSImage?

  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: contentMode)
          .transition(.opacity)
      }
    }
    .task(id: path) {
      if let cached = ThumbnailCache.shared.cached(path, side: side) {
        image = cached
        return
      }
      let loaded = await ThumbnailCache.shared.image(for: path, side: side, scale: scale)
      withAnimation(Motion.resolve(Motion.quick)) { image = loaded }
    }
  }
}
