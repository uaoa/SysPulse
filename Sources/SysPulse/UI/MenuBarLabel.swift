import SwiftUI

/// Те, що видно в menu bar завжди: два числа.
///
/// Це найдорожче місце додатка, бо система перемальовує рядок меню часто.
/// Тому тут немає ні графіків, ні анімацій, ні таймерів: лише текст, який
/// оновлюється, коли значення справді змінилось (див. крок таймера в Monitor).
/// Ширина фіксована моноширинними цифрами, щоб сусідні іконки не стрибали.
struct MenuBarLabel: View {
  @ObservedObject var monitor: Monitor

  private var level: Int { Format.verdict(monitor.snapshot).level }

  var body: some View {
    HStack(spacing: 6) {
      metric(
        value: monitor.snapshot.cpuTotal,
        symbol: "cpu",
        alarming: monitor.snapshot.cpuTotal > 0.85 || monitor.snapshot.loadPerCore > 1.5)
      metric(
        value: monitor.snapshot.memPressure,
        symbol: "memorychip",
        alarming: monitor.snapshot.memPressure > 0.9 || monitor.snapshot.swapOutsPerSec > 200)
    }
    // Підказка при наведенні: коротке пояснення стану без відкриття вікна.
    .help(Format.verdict(monitor.snapshot).text)
  }

  private func metric(value: Double, symbol: String, alarming: Bool) -> some View {
    HStack(spacing: 2) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .medium))
      Text("\(Int((value * 100).rounded()))%")
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
    }
    .foregroundStyle(alarming ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
  }
}
