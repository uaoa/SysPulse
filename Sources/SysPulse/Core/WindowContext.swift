import AppKit
import ApplicationServices

/// Заголовки вікон застосунків: «що саме там відкрито».
///
/// PID каже, що Chrome з'їв 4 ГБ, але не каже — чим саме. Заголовок вікна
/// каже: «Claude — рефакторинг білінгу», «Chrome — 47 вкладок, активна
/// така-то». Це перетворює список процесів на список справ.
///
/// Читаємо через Accessibility API: він єдиний працює однаково для всіх
/// застосунків — і для Chrome, і для Claude, і для Slack. Ціна — дозвіл
/// Accessibility, який користувач дає один раз.
///
/// ВАЖЛИВО про вартість: AX — це синхронний IPC до чужого процесу. Один
/// виклик коштує одиниці мілісекунд, а якщо застосунок підвис — блокує на
/// таймаут. Тому це ніколи не йде у фоновий цикл: лише за кнопкою, лише для
/// видимих застосунків, і з жорстким таймаутом на кожне звернення.
enum WindowContext {

  /// Що вдалось прочитати про один застосунок.
  struct Entry: Sendable {
    /// PID застосунку (головного процесу, не хелпера).
    let pid: Int32
    /// Заголовок активного вікна: назва вкладки, чату, документа.
    let title: String
    /// Скільки всього вікон відкрито.
    let windowCount: Int
  }

  /// Чи дав користувач дозвіл. Без запиту — просто перевірка.
  static var isAuthorized: Bool {
    AXIsProcessTrusted()
  }

  /// Показати системний запит дозволу. macOS сама відкриє Системні
  /// налаштування; відповідь приходить не одразу, тому результат тут не
  /// повертаємо — UI перечитує `isAuthorized` при наступному відкритті.
  static func requestAccess() {
    // Ключ заданий рядком, а не константою kAXTrustedCheckOptionPrompt:
    // та оголошена в C як змінна, і Swift 6 не вважає її Sendable.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  /// Заголовки вікон усіх застосунків з інтерфейсом.
  ///
  /// Обходимо лише `.regular` застосунки (ті, що в Dock): фонові агенти вікон
  /// не мають, а звернення до них — марний IPC.
  static func collect() -> [Int32: Entry] {
    guard isAuthorized else { return [:] }

    var result: [Int32: Entry] = [:]
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && !app.isTerminated {
      let pid = app.processIdentifier
      guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
      guard let entry = read(pid: pid) else { continue }
      result[pid] = entry
    }
    return result
  }

  /// Один застосунок. Повертає nil, якщо вікон немає або AX мовчить.
  private static func read(pid: Int32) -> Entry? {
    let element = AXUIElementCreateApplication(pid)
    // Таймаут на випадок підвислого застосунку: без нього AX блокує потік
    // до 6 с за замовчуванням, і вікно SysPulse завмирає разом із ним.
    AXUIElementSetMessagingTimeout(element, 0.25)

    var windowsValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue)
        == .success,
      let windows = windowsValue as? [AXUIElement], !windows.isEmpty
    else { return nil }

    // Активне вікно — те, яке система вважає головним; якщо його немає
    // (застосунок у фоні), беремо перше зі списку.
    var focused: CFTypeRef?
    let focusedWindow: AXUIElement? =
      AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &focused)
      == .success ? (focused as! AXUIElement) : windows.first

    guard let window = focusedWindow else { return nil }

    var titleValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
      let title = titleValue as? String, !title.isEmpty
    else { return nil }

    return Entry(pid: pid, title: clean(title), windowCount: windows.count)
  }

  /// Прибираємо технічний хвіст, який додають браузери й Electron.
  ///
  /// «Рефакторинг білінгу — Claude — Google Chrome» читається гірше, ніж
  /// «Рефакторинг білінгу»: назва застосунку і так поруч у списку.
  private static func clean(_ title: String) -> String {
    var text = title
    for suffix in [
      " - Google Chrome", " — Google Chrome", " - Chrome", " – Claude", " - Claude", " — Claude",
      " - Visual Studio Code", " — Visual Studio Code",
    ] where text.hasSuffix(suffix) {
      text.removeLast(suffix.count)
    }
    // Лічильник непрочитаних на початку рядка — шум для нашої задачі.
    if text.hasPrefix("("), let close = text.firstIndex(of: ")"),
      text.distance(from: text.startIndex, to: close) <= 5
    {
      text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
    return text.trimmingCharacters(in: .whitespaces)
  }
}
