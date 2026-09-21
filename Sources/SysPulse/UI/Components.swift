import SwiftUI

/// Спільні дрібні елементи. Навмисно без анімацій і тіней: кожен кадр
/// перемальовування коштує процесорного часу, а додаток має його економити.
enum Palette {
  static func level(_ level: Int) -> Color {
    switch level {
    case 3: return .red
    case 2: return .orange
    case 1: return .yellow
    default: return .green
    }
  }

  /// Колір смужки за завантаженням: спокійний до 60%, далі попереджає.
  static func load(_ value: Double) -> Color {
    if value > 0.9 { return .red }
    if value > 0.7 { return .orange }
    if value > 0.5 { return .yellow }
    return .accentColor
  }
}

/// Горизонтальна смужка заповнення.
struct Bar: View {
  let value: Double
  var color: Color?
  var height: CGFloat = 6

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: height / 2)
          .fill(Color.primary.opacity(0.08))
        RoundedRectangle(cornerRadius: height / 2)
          .fill(color ?? Palette.load(value))
          .frame(width: max(0, min(1, value)) * geometry.size.width)
      }
    }
    .frame(height: height)
  }
}

/// Рядок «назва — значення» зі смужкою.
struct MetricRow: View {
  let title: String
  let value: String
  let fraction: Double
  var hint: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(title)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Spacer()
        Text(value)
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
      }
      Bar(value: fraction)
      if let hint {
        Text(hint)
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
    }
  }
}

/// Смужки по ядрах: P і E окремо, бо саме P визначають, чи тягне машина.
struct CoreGrid: View {
  let values: [Double]
  let performanceCores: Int

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        VStack(spacing: 2) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .bottom) {
              RoundedRectangle(cornerRadius: 2)
                .fill(Palette.load(value))
                .frame(height: max(2, value * 26))
            }
            .frame(height: 26)
          // Підпис лише під першим ядром кожного типу — без візуального шуму.
          Text(index == 0 ? "P" : (index == performanceCores ? "E" : " "))
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}

/// Кнопка-дія у списку: маленька, спокійна, без тіней і зсувів на hover.
struct ActionButton: View {
  let title: String
  var destructive = false
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(
              hovering
                ? (destructive ? Color.red.opacity(0.18) : Color.primary.opacity(0.12))
                : (destructive ? Color.red.opacity(0.10) : Color.primary.opacity(0.06)))
        )
        .foregroundStyle(destructive ? Color.red : Color.primary)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
