import AppKit
import Quartz

/// Drives the shared Quick Look panel for a list of files.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  static let shared = QuickLookPreview()

  private var urls: [URL] = []

  var isVisible: Bool {
    QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
  }

  /// Opens the panel on `urls`, or closes it when it is already open.
  func toggle(_ urls: [URL]) {
    if isVisible {
      QLPreviewPanel.shared().orderOut(nil)
      return
    }
    show(urls)
  }

  func show(_ urls: [URL]) {
    guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
    self.urls = urls
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.currentPreviewItemIndex = 0
    panel.makeKeyAndOrderFront(nil)
  }

  /// Keeps an open panel in sync with the selection.
  func updateIfVisible(_ urls: [URL]) {
    guard isVisible else { return }
    if urls.isEmpty {
      QLPreviewPanel.shared().orderOut(nil)
    } else if urls != self.urls {
      self.urls = urls
      QLPreviewPanel.shared().reloadData()
    }
  }

  // MARK: - QLPreviewPanelDataSource

  nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    MainActor.assumeIsolated { urls.count }
  }

  nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int)
    -> (any QLPreviewItem)!
  {
    let url: URL? = MainActor.assumeIsolated {
      urls.indices.contains(index) ? urls[index] : nil
    }
    return url.map { $0 as NSURL }
  }
}
