import SwiftUI

/// Що саме показувати в menu bar.
///
/// Рядок меню — дефіцитне місце: там вже живуть години, батарея, Wi-Fi.
/// Хтось стежить за памʼяттю, хтось за процесором, а комусь потрібні обидва.
enum MenuBarMode: String, CaseIterable, Identifiable {
  case both
  case cpu
  case memory

  var id: String { rawValue }

  var title: String {
    switch self {
    case .both: return "CPU і ОЗУ"
    case .cpu: return "Лише CPU"
    case .memory: return "Лише ОЗУ"
    }
  }

  var showsCPU: Bool { self != .memory }
  var showsMemory: Bool { self != .cpu }
}

/// Налаштування додатка.
///
/// `@AppStorage` пише в UserDefaults — цього досить: налаштувань одиниці,
/// окремий файл конфігурації був би зайвою сутністю.
@MainActor
final class Settings: ObservableObject {
  @AppStorage("menuBarMode") var menuBarMode: MenuBarMode = .both
}
