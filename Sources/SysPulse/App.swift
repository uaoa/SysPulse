import ServiceManagement
import SwiftUI

/// SysPulse — монітор ресурсів, який сам ресурсів не споживає.
///
/// Додаток живе лише в menu bar (`.menuBarExtra`), іконки в Dock немає:
/// `LSUIElement` у Info.plist. Автозапуск при вході вмикається через
/// `SMAppService` — без сторонніх агентів і скриптів.
@main
struct SysPulseApp: App {
  @StateObject private var monitor = Monitor()
  @StateObject private var settings = Settings()

  var body: some Scene {
    MenuBarExtra {
      DetailView(monitor: monitor, settings: settings)
    } label: {
      MenuBarLabel(monitor: monitor, settings: settings)
    }
    .menuBarExtraStyle(.window)
  }
}

/// Автозапуск при вході. Вмикається один раз при першому старті; далі
/// користувач керує ним у Системних налаштуваннях.
enum LaunchAtLogin {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static func enable() {
    guard SMAppService.mainApp.status != .enabled else { return }
    try? SMAppService.mainApp.register()
  }

  static func disable() {
    try? SMAppService.mainApp.unregister()
  }
}
