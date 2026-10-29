import SectorCore
import SwiftUI

/// Main window: native sidebar and the selected screen.
struct MainView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 280)
    } detail: {
      ZStack {
        AmbientBackground()
        detail
          .id(model.showsScan ? "scan" : model.route.rawValue)
          .transition(.opacity.combined(with: .offset(y: 8)))
      }
      .animation(Motion.resolve(Motion.smooth), value: model.route)
      .animation(Motion.resolve(Motion.smooth), value: model.showsScan)
      .overlay(alignment: .bottom) { ToastView() }
    }
    .sheet(item: $model.deletionRequest) { request in
      ConfirmDeleteSheet(request: request)
    }
  }

  @ViewBuilder private var detail: some View {
    if model.showsScan || model.tree == nil {
      ScanView()
    } else {
      switch model.route {
      case .overview: OverviewView()
      case .explorer: ExplorerView()
      case .smartClean: SmartCleanView()
      case .largeFiles: LargeFilesView()
      case .duplicates: DuplicatesView()
      case .apps: AppsView()
      case .history: HistoryView()
      }
    }
  }
}

/// Sidebar with "Диск" and "Инструменты" sections and the disk summary.
struct SidebarView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    List(selection: Binding<Route?>(
      get: { model.showsScan ? nil : model.route },
      set: { route in
        if let route {
          model.route = route
          if model.tree != nil { model.showsScan = false }
        }
      })
    ) {
      Section("Диск") {
        ForEach(Route.disk) { route in row(route) }
      }
      Section("Инструменты") {
        ForEach(Route.tools) { route in row(route) }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { DiskSummary().padding(12) }
  }

  @ViewBuilder private func row(_ route: Route) -> some View {
    Label(route.title, systemImage: route.symbol)
      .badge(badge(for: route))
      .tag(route)
  }

  private func badge(for route: Route) -> Text? {
    guard route == .smartClean, model.smartClean.reclaimableBytes > 0 else { return nil }
    return Text(ByteFormat.string(model.smartClean.reclaimableBytes))
  }
}

/// "Macintosh HD · 123,4 ГБ свободно из 994,7 ГБ" with a usage bar.
struct DiskSummary: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let volume = model.volume {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "internaldrive").foregroundStyle(.secondary)
          Text(volume.name).font(.system(size: 12, weight: .semibold))
        }
        GeometryReader { geo in
          Capsule().fill(Color.sectorTrack)
            .overlay(alignment: .leading) {
              Capsule().fill(volume.usedFraction > 0.9 ? Color.sectorDanger : Color.sectorAccent)
                .frame(width: geo.size.width * volume.usedFraction)
            }
        }
        .frame(height: 5)
        Text("\(ByteFormat.string(volume.available)) свободно из \(ByteFormat.string(volume.total))")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .padding(12)
      .background(.background.opacity(0.5), in: .rect(cornerRadius: Metrics.rowRadius))
    }
  }
}

/// Bottom toast with optional "Отменить".
struct ToastView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      if let toast = model.toast {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sectorSuccess)
          Text(toast.text).font(.system(size: 13, weight: .medium))
          if let undo = toast.undo {
            Button("Отменить") {
              undo()
              model.toast = nil
            }
            .buttonStyle(.glass)
            .controlSize(.small)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: toast.id) {
          try? await Task.sleep(for: .seconds(5))
          if model.toast?.id == toast.id { model.toast = nil }
        }
      }
    }
    .animation(Motion.resolve(Motion.bouncy), value: model.toast)
  }
}
