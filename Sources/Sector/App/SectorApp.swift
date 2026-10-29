import AppKit
import SectorCore
import SwiftUI

@main
struct SectorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model: AppModel

  init() {
    let model = AppModel()
    _model = State(initialValue: model)
    SystemServices.start(model: model)
  }

  var body: some Scene {
    Window("Sector", id: "main") {
      RootView()
        .environment(model)
        .capturesOpenWindow()
        .frame(minWidth: 1080, minHeight: 700)
    }
    .defaultSize(width: 1280, height: 800)
    .windowToolbarStyle(.unified)
    .commands { SectorCommands(model: model) }

    Settings {
      SettingsView()
        .environment(model)
    }

    MenuBarExtra(isInserted: Binding(
      get: { model.settings.showInMenuBar },
      set: { model.settings.showInMenuBar = $0 })
    ) {
      MenuBarView()
        .environment(model)
    } label: {
      MenuBarLabel()
        .environment(model)
    }
    .menuBarExtraStyle(.window)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Keep running in the menu bar.
    false
  }
}

struct SectorCommands: Commands {
  let model: AppModel

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Сканировать снова") { model.startScan() }
        .keyboardShortcut("r")
        .disabled(model.isScanning)
    }
    CommandMenu("Перейти") {
      ForEach(Array(Route.allCases.enumerated()), id: \.element) { index, route in
        Button(route.title) {
          model.showsScan = false
          model.route = route
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
      }
    }
  }
}
