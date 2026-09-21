import Foundation

/// Числа у вигляді, зрозумілому з першого погляду.
enum Format {

  static func bytes(_ value: UInt64) -> String {
    let gb = Double(value) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f ГБ", gb) }
    let mb = Double(value) / 1_048_576
    if mb >= 1 { return String(format: "%.0f МБ", mb) }
    return String(format: "%.0f КБ", Double(value) / 1024)
  }

  static func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  /// Тривалість словами: «2 дні», «3 год», «15 хв».
  static func duration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "\(Int(seconds)) с" }
    if seconds < 3600 { return "\(Int(seconds / 60)) хв" }
    if seconds < 86400 {
      let hours = Int(seconds / 3600)
      let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
      return minutes > 0 ? "\(hours) год \(minutes) хв" : "\(hours) год"
    }
    let days = Int(seconds / 86400)
    let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
    let word = days == 1 ? "день" : (days < 5 ? "дні" : "днів")
    return hours > 0 ? "\(days) \(word) \(hours) год" : "\(days) \(word)"
  }

  /// Стан машини одним рядком — головне, що має читатись без розбору цифр.
  static func verdict(_ snap: SystemSnapshot) -> (text: String, level: Int) {
    if snap.swapOutsPerSec > 200 {
      return ("Памʼяті не вистачає: система вивантажує її на диск просто зараз", 3)
    }
    if snap.memPressure > 0.92 {
      return ("Памʼять на межі: \(percent(snap.memPressure)) зайнято", 3)
    }
    if snap.loadPerCore > 1.5 {
      return (
        "Процесор перевантажений: черга \(String(format: "%.1f", snap.loadAverage.0)) на \(snap.perCore.count) ядер",
        2
      )
    }
    if snap.swapPressure > 0.7 {
      return ("Своп заповнений на \(percent(snap.swapPressure)): памʼяті бракувало", 2)
    }
    if snap.cpuTotal > 0.85 {
      return ("Процесор завантажений на \(percent(snap.cpuTotal))", 1)
    }
    if snap.memPressure > 0.8 {
      return ("Памʼять заповнена на \(percent(snap.memPressure))", 1)
    }
    return ("Машина спокійна", 0)
  }
}
