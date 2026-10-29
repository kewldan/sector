import SectorCore
import SwiftUI

/// Actions on a disk-map item, shared by the inspector and context menu.
@MainActor
enum ExplorerActions {
  /// Folders Sector never offers to trash from the map.
  private static let protectedPaths: Set<String> = [
    "/", "/Users", "/System", "/Applications", "/Library", "/private", "/usr", "/bin", "/sbin",
    "/opt", "/Volumes", NSHomeDirectory(), NSHomeDirectory() + "/Library",
  ]

  static func canTrash(_ node: NodeID, tree: FileTree) -> Bool {
    guard node != FileTree.root, !tree.isRemoved(node) else { return false }
    let path = tree.path(node)
    return !protectedPaths.contains(path) && !path.hasPrefix("/System/")
  }

  static func reveal(_ node: NodeID, app: AppModel) {
    guard let tree = app.tree else { return }
    app.revealInFinder([tree.url(node)])
  }

  static func trash(_ node: NodeID, app: AppModel) {
    guard let tree = app.tree, canTrash(node, tree: tree) else { return }
    let item = DeletionItem(url: tree.url(node), size: tree.size(node))
    app.requestDeletion(
      DeletionRequest(items: [item], source: .explorer, recordTitle: tree.name(node)))
  }
}

/// Right-click menu for the item under the pointer.
struct ExplorerContextMenu: View {
  @Environment(AppModel.self) private var app
  let explorer: ExplorerModel

  var body: some View {
    if let tree = app.tree, let hover = explorer.hover, !hover.isOther {
      let node = hover.node
      if tree.isDirectory(node) {
        Button("Открыть") { explorer.zoom(to: node) }
      }
      Button("Показать в Finder") { ExplorerActions.reveal(node, app: app) }
      Divider()
      Button("В Корзину", role: .destructive) { ExplorerActions.trash(node, app: app) }
        .disabled(!ExplorerActions.canTrash(node, tree: tree))
    }
  }
}

/// Right panel: what the pointer is on (or the selection, or the focus
/// folder) with its size, share, dates and largest children.
struct ExplorerInspector: View {
  @Environment(AppModel.self) private var app
  let explorer: ExplorerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let tree = app.tree {
        content(info(tree), tree: tree)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 18)
    .padding(.bottom, 14)
    .frame(width: 292)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
  }

  // MARK: - Model

  private struct Child: Identifiable, Equatable {
    var id: NodeID
    var name: String
    var size: UInt64
    var color: Color
    var fraction: Double
  }

  private struct Info: Equatable {
    var node: NodeID
    var isOther: Bool
    var name: String
    var path: String
    var symbol: String
    var color: Color
    var size: UInt64
    var share: Double
    var shareText: String
    var modified: String
    var count: String
    var kind: String
    var listTitle: LocalizedStringKey
    var children: [Child]
  }

  private func info(_ tree: FileTree) -> Info {
    let palette = ExplorerPalette(breakdown: app.breakdown)
    if let hover = explorer.hover, hover.isOther {
      let parent = hover.node
      let parentSize = tree.size(parent)
      return Info(
        node: parent, isOther: true, name: String(localized: "Прочее"),
        path: ExplorerFormat.displayPath(tree.path(parent)), symbol: "ellipsis.circle",
        color: .secondary, size: hover.size, share: share(hover.size, parentSize),
        shareText: String(
          localized: "\(ExplorerFormat.percent(hover.size, of: parentSize)) от \(tree.name(parent))"
        ),
        modified: "—",
        count: Plural.format(hover.otherCount, "объект", "объекта", "объектов"),
        kind: String(localized: "Мелкие объекты"), listTitle: "Содержимое", children: [])
    }
    let node = explorer.hover?.node ?? explorer.selection ?? explorer.focus
    let category = palette.category(node)
    let size = tree.size(node)
    let isDir = tree.isDirectory(node)

    var shareText: String
    var fraction: Double
    if let parent = tree.parent(node) {
      let parentSize = tree.size(parent)
      fraction = share(size, parentSize)
      shareText = String(
        localized: "\(ExplorerFormat.percent(size, of: parentSize)) от \(tree.name(parent))")
    } else {
      let total = app.volume?.total ?? size
      fraction = share(size, total)
      shareText = String(localized: "\(ExplorerFormat.percent(size, of: total)) диска")
    }

    var children: [Child] = []
    if isDir {
      let top = tree.largestChildren(node, limit: 6)
      let largest = top.first.map { tree.size($0) } ?? 1
      children = top.map { child in
        Child(
          id: child, name: tree.name(child), size: tree.size(child),
          color: palette.base(child), fraction: share(tree.size(child), largest))
      }
    }

    let name =
      node == FileTree.root
      ? (explorer.crumbs.first(where: { $0.node == FileTree.root })?.name ?? tree.name(node))
      : tree.name(node)
    let files = tree.fileCount(node)
    return Info(
      node: node, isOther: false, name: name,
      path: ExplorerFormat.displayPath(tree.path(node)), symbol: symbol(node, tree: tree),
      color: node == FileTree.root ? .sectorAccent : category.color, size: size, share: fraction,
      shareText: shareText, modified: ExplorerFormat.modified(tree.modificationDate(node)),
      count: isDir ? files.formatted(.number) : "1",
      kind: ExplorerFormat.kind(node, tree: tree, category: category),
      listTitle: "Содержимое", children: children)
  }

  private func share(_ part: UInt64, _ whole: UInt64) -> Double {
    whole == 0 ? 0 : min(1, Double(part) / Double(whole))
  }

  private func symbol(_ node: NodeID, tree: FileTree) -> String {
    if node == FileTree.root && tree.rootPath == "/" { return "internaldrive" }
    let flags = tree.flags(node)
    if flags.contains(.symlink) { return "link" }
    if flags.contains(.package) {
      return tree.pathExtension(node) == "app" ? "app.badge" : "shippingbox"
    }
    if flags.contains(.directory) { return "folder" }
    switch tree.pathExtension(node) {
    case "jpg", "jpeg", "png", "heic", "gif", "tiff", "raw", "dng", "webp": return "photo"
    case "mov", "mp4", "m4v", "avi", "mkv", "webm": return "film"
    case "mp3", "m4a", "aac", "wav", "aiff", "flac": return "music.note"
    case "zip", "gz", "tar", "rar", "7z", "xip": return "archivebox"
    case "dmg", "iso", "img", "raw2", "vmdk", "qcow2": return "externaldrive"
    default: return "doc"
    }
  }

  // MARK: - Views

  @ViewBuilder
  private func content(_ info: Info, tree: FileTree) -> some View {
    HStack(spacing: 12) {
      Image(systemName: info.symbol)
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(info.color)
        .frame(width: 46, height: 46)
        .background(info.color.opacity(0.13), in: .rect(cornerRadius: 14))
        .contentTransition(.symbolEffect(.replace))
      VStack(alignment: .leading, spacing: 2) {
        Text(info.name)
          .font(.system(size: 15, weight: .bold))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(info.path)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
          .help(info.path)
      }
    }

    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(ByteFormat.string(info.size))
        .font(.system(size: 28, weight: .bold))
        .monospacedDigit()
        .contentTransition(.numericText(value: Double(info.size)))
      Text(info.shareText)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.top, 14)

    GeometryReader { geo in
      Capsule().fill(Color.sectorTrack)
        .overlay(alignment: .leading) {
          Capsule().fill(info.color)
            .frame(width: max(4, geo.size.width * info.share))
        }
    }
    .frame(height: 6)
    .padding(.top, 8)
    .animation(Motion.resolve(Motion.smooth), value: info.share)

    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
      row("Изменено", info.modified)
      row("Объектов", info.count)
      row("Тип", info.kind)
    }
    .font(.system(size: 12))
    .padding(.top, 14)

    Divider().padding(.top, 14).padding(.bottom, 10)

    if !info.children.isEmpty {
      Text(info.listTitle)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
      VStack(spacing: 2) {
        ForEach(info.children) { child in
          ChildRow(
            name: child.name, size: child.size, color: child.color, fraction: child.fraction
          ) {
            explorer.activate(node: child.id, isOther: false)
          }
        }
      }
    } else if info.isOther {
      Text("Объекты слишком малы, чтобы показать их отдельно. Откройте папку, чтобы увидеть их.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    Spacer(minLength: 10)

    HStack(spacing: 8) {
      Button {
        ExplorerActions.reveal(info.node, app: app)
      } label: {
        Text("Показать в Finder").frame(maxWidth: .infinity)
      }
      .buttonStyle(.glass)
      Button(role: .destructive) {
        ExplorerActions.trash(info.node, app: app)
      } label: {
        Label("В Корзину", systemImage: "trash").frame(maxWidth: .infinity)
      }
      .buttonStyle(.glass)
      .tint(.sectorDanger)
      .foregroundStyle(Color.sectorDanger)
      .disabled(info.isOther || !ExplorerActions.canTrash(info.node, tree: tree))
    }
    .font(.system(size: 12, weight: .semibold))
    .controlSize(.large)
    .disabled(info.isOther)
  }

  private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value)
        .monospacedDigit()
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}

/// A child in the inspector list: color chip, name, share bar and size.
private struct ChildRow: View {
  var name: String
  var size: UInt64
  var color: Color
  var fraction: Double
  var action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8)
        Text(name).lineLimit(1).truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        Capsule().fill(Color.sectorTrack)
          .frame(width: 54, height: 4)
          .overlay(alignment: .leading) {
            Capsule().fill(color).frame(width: max(2, 54 * fraction), height: 4)
          }
        Text(ByteFormat.string(size))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .frame(width: 62, alignment: .trailing)
      }
      .font(.system(size: 12))
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .background(
        Color.sectorAccent.opacity(hovered ? 0.08 : 0), in: .rect(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .animation(Motion.resolve(Motion.quick), value: hovered)
  }
}
