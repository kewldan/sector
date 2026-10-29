import SectorCore
import SwiftUI

/// "Обзор": disk status, usage by category, Smart Clean, the free-space
/// trend, largest folders and quick actions.
/// Implements design/mockups/Overview.dc.html.
struct OverviewView: View {
  @Environment(AppModel.self) private var model
  private let overview = OverviewModel.shared

  private struct RefreshKey: Equatable {
    var version: Int
    var minimumAgeDays: Int
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        DiskStatusBanner()

        UsageCard()
          .appearAnimation(delay: 0.1)

        HStack(spacing: 14) {
          OverviewSmartCleanCard()
            .appearAnimation(delay: 0.2)
          ForecastCard()
            .appearAnimation(delay: 0.28)
        }
        .frame(height: 154)

        RatioRow(ratio: 1.7, spacing: 14) {
          LargestFoldersCard(folders: overview.snapshot?.folders)
            .appearAnimation(delay: 0.36)
          QuickActionsCard(snapshot: overview.snapshot)
            .appearAnimation(delay: 0.44)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 4)
      .padding(.bottom, 20)
    }
    .scrollIndicators(.automatic)
    .navigationTitle("Обзор")
    .navigationSubtitle(checkedText)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.startScan()
        } label: {
          Label("Сканировать снова", systemImage: "arrow.clockwise")
        }
        .help("Сканировать снова")
        .disabled(model.isScanning)
      }
    }
    .task(id: refreshKey) {
      await overview.refresh(app: model)
    }
  }

  private var refreshKey: RefreshKey {
    RefreshKey(version: model.treeVersion, minimumAgeDays: model.settings.minimumAgeDays)
  }

  private var checkedText: String {
    guard let date = model.tree?.scannedAt else { return "" }
    if Date().timeIntervalSince(date) < 90 { return String(localized: "Проверено только что") }
    let relative = date.formatted(.relative(presentation: .named))
    return String(localized: "Проверено \(relative)")
  }
}
