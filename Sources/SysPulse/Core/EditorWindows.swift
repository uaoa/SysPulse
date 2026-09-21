import Foundation

/// Які теки відкриті у VS Code.
///
/// «Code Helper (Renderer) × 12» не пояснює нічого; «VS Code · SysPulse» —
/// пояснює все. Заголовок вікна через Accessibility тут ненадійний: дозвіл
/// дають рідко, і без нього підпис просто зникає.
///
/// Натомість VS Code сам тримає список відкритих вікон у власному сховищі —
/// `storage.json`, ключ `backupWorkspaces`. Це звичайний JSON, читається без
/// жодних дозволів і оновлюється, коли вікна відкривають чи закривають.
enum EditorWindows {

  /// Тека, відкрита в редакторі.
  struct Folder: Sendable {
    /// Назва теки — те, що людина бачить у заголовку вікна.
    let name: String
    /// Повний шлях: за ним зіставляємо вікно з процесами й сесіями.
    let path: String
  }

  /// Сховища відомих збірок VS Code. Insiders і VSCodium тримають свої
  /// налаштування окремо, але формат у них однаковий.
  private static let storages = [
    "Code", "Code - Insiders", "VSCodium",
  ]

  /// Відкриті теки всіх знайдених збірок редактора.
  static func folders() -> [Folder] {
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support")

    var seen = Set<String>()
    var result: [Folder] = []
    for storage in storages {
      let url = support.appendingPathComponent(
        "\(storage)/User/globalStorage/storage.json")
      for path in read(url) where !seen.contains(path) {
        seen.insert(path)
        result.append(
          Folder(name: URL(fileURLWithPath: path).lastPathComponent, path: path))
      }
    }
    return result
  }

  /// Шляхи відкритих тек з одного `storage.json`.
  private static func read(_ url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let backups = root["backupWorkspaces"] as? [String: Any]
    else { return [] }

    // `folders` — вікна з відкритою текою; `workspaces` — з файлом .code-workspace.
    // Порожні вікна (`emptyWindows`) пропускаємо: підписувати там нічого.
    var paths: [String] = []
    for key in ["folders", "workspaces"] {
      guard let entries = backups[key] as? [[String: Any]] else { continue }
      for entry in entries {
        let uri = (entry["folderUri"] ?? entry["configURIPath"]) as? String
        guard let uri, let path = URL(string: uri)?.path, !path.isEmpty else { continue }
        paths.append(path)
      }
    }
    return paths
  }
}
