import Foundation

/// Вкладки браузера.
///
/// Accessibility тут не рятує: у вікна Chrome один заголовок — активної
/// вкладки, а решта сорока лишаються невидимими. Повний список дає лише сам
/// Chrome через AppleScript.
///
/// Зіставити вкладку з конкретним процесом-рендерером не можна: Chrome не
/// публікує цього зв'язку. Тому показуємо вкладки як окремий список «що
/// відкрито», а не як підпис до кожного процесу — чесніше, ніж вигадувати
/// відповідність, якої немає.
enum BrowserTabs {

  struct Tab: Identifiable, Sendable {
    var id: String { "\(windowIndex)-\(index)-\(title)" }
    let title: String
    let host: String
    let windowIndex: Int
    let index: Int
    /// Чи це активна вкладка свого вікна — та, яку справді видно.
    let active: Bool
  }

  /// Читання вкладок Chrome. Повертає nil, якщо Chrome не запущено або
  /// дозволу на автоматизацію немає.
  ///
  /// Коштує 50–200 мс і потребує дозволу Automation, тому викликається
  /// виключно з кнопки, ніколи з фонового циклу.
  static func chrome() -> [Tab]? {
    // Розділювачі, яких не буває в заголовках сторінок.
    let script = """
      tell application "Google Chrome"
        if not running then return ""
        set output to ""
        set windowIndex to 0
        repeat with w in windows
          set windowIndex to windowIndex + 1
          set activeIndex to active tab index of w
          set tabIndex to 0
          repeat with t in tabs of w
            set tabIndex to tabIndex + 1
            set output to output & windowIndex & "\u{1}" & tabIndex & "\u{1}" & (activeIndex as text) & "\u{1}" & (title of t) & "\u{1}" & (URL of t) & "\u{2}"
          end repeat
        end repeat
        return output
      end tell
      """

    guard let raw = run(script), !raw.isEmpty else { return nil }

    var tabs: [Tab] = []
    for record in raw.components(separatedBy: "\u{2}") where !record.isEmpty {
      let fields = record.components(separatedBy: "\u{1}")
      guard fields.count >= 5,
        let windowIndex = Int(fields[0]), let index = Int(fields[1]),
        let activeIndex = Int(fields[2])
      else { continue }
      let title = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { continue }
      tabs.append(
        Tab(
          title: title,
          host: host(of: fields[4]),
          windowIndex: windowIndex,
          index: index,
          active: index == activeIndex))
    }
    return tabs
  }

  /// Чи дано дозвіл на автоматизацію Chrome. Перевіряємо найдешевшим
  /// запитом — кількістю вікон.
  static func chromeAuthorized() -> Bool {
    run("tell application \"Google Chrome\" to return count of windows") != nil
  }

  private static func run(_ source: String) -> String? {
    guard let script = NSAppleScript(source: source) else { return nil }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    // Помилка тут — це або відмова в дозволі, або Chrome не запущено;
    // і те, і те означає «показати нічого», а не аварію.
    guard error == nil else { return nil }
    return result.stringValue
  }

  /// Домен без `www.` — для групування вкладок за сайтом.
  private static func host(of url: String) -> String {
    guard let host = URL(string: url)?.host else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}
