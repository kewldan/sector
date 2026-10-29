import AppKit
import Observation
import SectorCore

/// App-lifetime services outside the UI: notifications, the weekly
/// background scan, volume mount events and a periodic free-space check.
/// Started once from `SectorApp.init`.
@MainActor
final class SystemServices {
  private static var current: SystemServices?

  static func start(model: AppModel) {
    guard current == nil else { return }
    let services = SystemServices(model: model)
    current = services
    services.run()
  }

  private let model: AppModel
  private let notifications: NotificationService
  private let scheduler: BackgroundScheduler
  private let widgets: WidgetBridge
  private var observers: [NSObjectProtocol] = []
  private var ticker: Task<Void, Never>?

  private init(model: AppModel) {
    self.model = model
    notifications = NotificationService(model: model)
    scheduler = BackgroundScheduler(model: model, notifications: notifications)
    widgets = WidgetBridge(model: model)
  }

  private func run() {
    notifications.start()
    scheduler.start()
    widgets.start()
    observeVolume()

    let workspace = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
      NSWorkspace.didRenameVolumeNotification,
    ] {
      observers.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.model.refreshVolume() }
        })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.model.refreshDiskAccess() }
      })

    ticker = Task { [weak self] in
      try? await Task.sleep(for: .seconds(20))
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(for: .seconds(600))
      }
    }
  }

  /// Checks free space after every `refreshVolume`.
  private func observeVolume() {
    withObservationTracking {
      _ = model.volume
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.notifications.checkLowSpace(self.model.volume)
        self.observeVolume()
      }
    }
  }

  /// Every ~10 minutes: re-reads free space off the main actor and only
  /// refreshes the model (menu bar label, samples) when it moved.
  private func tick() async {
    let fresh = await Task.detached(priority: .utility) { VolumeInfo.startup() }.value
    if let fresh, let current = model.volume {
      let delta = fresh.available > current.available
        ? fresh.available - current.available : current.available - fresh.available
      if delta > 256 * 1_000_000 {
        model.refreshVolume()
      } else {
        notifications.checkLowSpace(fresh)
      }
    } else {
      model.refreshVolume()
    }
    notifications.checkMonthly()
  }
}
