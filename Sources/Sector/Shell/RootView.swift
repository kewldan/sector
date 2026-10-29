import SectorCore
import SwiftUI

/// Switches between onboarding and the main window content.
struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      switch model.phase {
      case .welcome:
        WelcomeView()
          .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.98))))
      case .permission:
        PermissionView()
          .transition(.opacity.combined(with: .move(edge: .trailing)))
      case .main:
        MainView()
          .transition(.opacity)
      }
    }
    .animation(Motion.resolve(Motion.smooth), value: model.phase)
    .task {
      if model.phase == .main && model.tree == nil && !model.isScanning {
        model.startScan()
      }
    }
  }
}
