import Foundation

/// Назви сесій Claude Code з її власних журналів.
///
/// Accessibility тут не допоміг би: сесія Claude Code — це процес у терміналі
/// або в VS Code, власного вікна він не має. Зате Claude Code веде журнал
/// кожної сесії у `~/.claude/projects/<шлях-проєкту>/<uuid>.jsonl`, і в ньому
/// є поле `aiTitle` — назва, яку модель дала розмові. Саме вона відповідає на
/// питання «а що в цій сесії робиться».
///
/// Читаємо лише файли, нічого не запускаємо й не змінюємо: жодних хуків у
/// `settings.json`, на відміну від інших моніторів Claude Code.
enum ClaudeSessions {

  /// Чим сесія зайнята просто зараз.
  ///
  /// Визначаємо за останнім записом журналу: після репліки людини черга за
  /// Claude, після його відповіді — за людиною. Точніше без хуків у
  /// `settings.json` не дістати, а лізти в чужий конфіг заради статусу не варто.
  enum State: Sendable {
    /// Останнє слово за людиною — Claude обробляє запит.
    case working
    /// Claude відповів і чекає.
    case waiting
    /// Журнал давно не оновлювався.
    case idle

    var label: String {
      switch self {
      case .working: return "працює"
      case .waiting: return "чекає на вас"
      case .idle: return "без активності"
      }
    }
  }

  /// Після цього часу без записів сесія вважається покинутою.
  static let idleThreshold: TimeInterval = 15 * 60

  /// Те, що вдалось дізнатись про одну сесію.
  struct Session: Sendable {
    /// Назва розмови: «Зупинення зависає на модальному вікні».
    let title: String
    /// Тека проєкту, в якій сесію запущено.
    let directory: String
    /// Коли журнал востаннє змінювався — тобто коли сесія працювала.
    let modified: Date
    let state: State

    /// Скільки часу минуло з останньої активності.
    var silence: TimeInterval { Date().timeIntervalSince(modified) }
  }

  private static let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects")

  /// Назви сесій за робочою текою.
  ///
  /// Claude Code кодує шлях у назву теки, замінюючи `/` на `-`, тож зіставити
  /// процес із журналом можна за його `cwd` — його SysPulse уже читає.
  /// Якщо в теці кілька сесій, беремо найсвіжішу: саме в ній людина працює.
  static func byDirectory() -> [String: Session] {
    let manager = FileManager.default
    guard
      let projects = try? manager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return [:] }

    var result: [String: Session] = [:]
    for project in projects {
      guard
        let files = try? manager.contentsOfDirectory(
          at: project, includingPropertiesForKeys: [.contentModificationDateKey])
      else { continue }

      // Найсвіжіший журнал у теці — поточна сесія проєкту.
      let newest =
        files
        .filter { $0.pathExtension == "jsonl" }
        .compactMap { url -> (URL, Date)? in
          guard
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
              .contentModificationDate
          else { return nil }
          return (url, date)
        }
        .max { $0.1 < $1.1 }

      guard let (url, modified) = newest, let session = read(url, modified: modified) else {
        continue
      }
      result[session.directory] = session
    }
    return result
  }

  /// Назва й тека однієї сесії.
  ///
  /// Журнал сесії росте до мегабайтів, а потрібні з нього два поля. Тому
  /// читаємо не файл цілком, а його хвіст: `aiTitle` оновлюється протягом
  /// розмови, тож найсвіжіше значення — саме в кінці.
  private static func read(_ url: URL, modified: Date) -> Session? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    let size = (try? handle.seekToEnd()) ?? 0
    // 256 КБ з кінця: вистачає на кілька останніх записів навіть із великими
    // результатами інструментів, і це стеля витрат незалежно від розміру.
    let window: UInt64 = 256 * 1024
    let offset = size > window ? size - window : 0
    try? handle.seek(toOffset: offset)
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
      return nil
    }

    var title: String?
    var directory: String?
    // Хто говорив останнім: за цим визначаємо, чия зараз черга.
    var lastSpeaker: String?
    // Знизу вгору: перше знайдене — найновіше.
    for line in text.split(separator: "\n").reversed() {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { continue }
      if let type = object["type"] as? String, lastSpeaker == nil,
        type == "user" || type == "assistant"
      {
        lastSpeaker = type
      }
      if title == nil, let value = object["aiTitle"] as? String, !value.isEmpty {
        title = value
      }
      if directory == nil, let value = object["cwd"] as? String, !value.isEmpty {
        directory = value
      }
      if title != nil && directory != nil && lastSpeaker != nil { break }
    }

    guard let title, let directory else { return nil }

    let state: State
    if Date().timeIntervalSince(modified) > idleThreshold {
      state = .idle
    } else {
      state = lastSpeaker == "user" ? .working : .waiting
    }
    return Session(title: title, directory: directory, modified: modified, state: state)
  }
}
