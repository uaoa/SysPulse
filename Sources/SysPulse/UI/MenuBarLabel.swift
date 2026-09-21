import SwiftUI

/// Те, що видно в menu bar завжди: одне або два числа.
///
/// Це найдорожче місце додатка, бо система перемальовує рядок меню часто.
/// Тому тут немає ні графіків, ні анімацій, ні таймерів: лише текст, який
/// оновлюється, коли значення справді змінилось (див. крок таймера в Monitor).
///
/// Чому текст, а не SF Symbols: `MenuBarExtra` міряє свій label один раз і
/// обрізає його по ширині, розрахованій приблизно під одну іконку. З двома
/// парами «іконка + число» другу пару просто не було видно. Літери C і M
/// коштують кілька пунктів ширини й ніколи не зникають.
struct MenuBarLabel: View {
  @ObservedObject var monitor: Monitor
  @ObservedObject var settings: Settings

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(alarming ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
      // Підказка при наведенні: коротке пояснення стану без відкриття вікна.
      .help(Format.verdict(monitor.snapshot).text)
  }

  /// Готовий рядок. Складаємо його самі, а не з кількох `Text`, бо система
  /// міряє label цілком — окремі елементи вона обрізає.
  private var text: String {
    var parts: [String] = []
    if settings.menuBarMode.showsCPU {
      parts.append("C \(percent(monitor.snapshot.cpuTotal))")
    }
    if settings.menuBarMode.showsMemory {
      parts.append("M \(percent(monitor.snapshot.memPressure))")
    }
    return parts.joined(separator: "  ")
  }

  /// Червоніємо лише через те, що справді показуємо: якщо ОЗУ сховано, тривога
  /// за памʼяттю не має фарбувати число процесора.
  private var alarming: Bool {
    let cpuAlarm =
      settings.menuBarMode.showsCPU
      && (monitor.snapshot.cpuTotal > 0.85 || monitor.snapshot.loadPerCore > 1.5)
    let memoryAlarm =
      settings.menuBarMode.showsMemory
      && (monitor.snapshot.memPressure > 0.9 || monitor.snapshot.swapOutsPerSec > 200)
    return cpuAlarm || memoryAlarm
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }
}
