import Foundation

/// Перетворює сирий рядок запуску на людську назву.
///
/// Заради цього все й робиться: `bun *:52924 (PID 10547)` нічого не пояснює,
/// а «Профайлер bun · працює 2 доби» — пояснює. Розпізнавання суто текстове,
/// по вже прочитаних аргументах, тож не коштує нічого понад сам збір.
enum Identifier {

  /// Назва проєкту з будь-якого шляху виду `…/Projects/<Назва>/…`.
  static func project(in text: String) -> String? {
    guard let range = text.range(of: "/Projects/") else { return nil }
    let tail = text[range.upperBound...]
    let name = tail.prefix { $0 != "/" && $0 != " " }
    return name.isEmpty ? nil : String(name)
  }

  /// Людська назва процесу + група, до якої його складати.
  static func describe(name: String, command: String?, cwd: String?) -> (
    label: String, group: String?
  ) {
    let text = command ?? name
    let projectName = project(in: text) ?? cwd.flatMap(project(in:))
    let suffix = projectName.map { " · \($0)" } ?? ""

    // ── Claude Code ─────────────────────────────────────────────────────
    // Кожна сесія — окремий процес; поруч живуть її MCP-сервери й оболонки.
    if text.contains("claude-code") || text.contains("/claude ") || name == "claude" {
      if text.contains("--chrome-native-host") {
        return ("Claude · міст до Chrome", "Claude Code")
      }
      if text.contains("mcp") {
        return ("Claude · MCP-сервер\(suffix)", "Claude Code")
      }
      return ("Claude Code · сесія\(suffix.isEmpty ? "" : suffix)", "Claude Code")
    }
    if text.contains("next-devtools-mcp") {
      return ("MCP Next DevTools", "Claude Code")
    }

    // ── Дев-сервери й збірка ────────────────────────────────────────────
    if text.contains("next dev") || text.contains("next-server") {
      return ("Next.js dev-сервер\(suffix)", "Next.js\(suffix)")
    }
    if text.contains("next build") || text.contains("next/dist/build") {
      return ("Next.js build\(suffix)", "Next.js\(suffix)")
    }
    if text.contains("next start") {
      return ("Next.js прод-сервер\(suffix)", "Next.js\(suffix)")
    }
    if text.contains("vitest") {
      return ("Vitest\(suffix)", "Vitest\(suffix)")
    }
    if text.contains("tsc --lsp") || text.contains("tsgo") {
      return ("TypeScript: мовний сервер\(suffix)", nil)
    }
    if text.contains("tsserver.js") {
      return ("TypeScript: старий tsserver (JS)", nil)
    }
    if text.contains("--cpu-prof") {
      return ("Профайлер bun", nil)
    }
    if text.contains("biome") {
      return ("Biome\(suffix)", nil)
    }
    if text.contains("esbuild") { return ("esbuild", nil) }

    // ── Бази й інфраструктура ───────────────────────────────────────────
    if name.hasPrefix("postgres") { return ("PostgreSQL", "PostgreSQL") }
    if name.hasPrefix("redis") { return ("Redis", nil) }
    if text.contains("pm2") { return ("PM2", nil) }
    if name == "bun" { return ("Bun\(suffix)", nil) }
    if name == "node" { return ("Node\(suffix)", nil) }

    // ── Застосунки ──────────────────────────────────────────────────────
    if text.contains("Google Chrome") { return ("Chrome", "Chrome") }
    if text.contains("Visual Studio Code") || name.hasPrefix("Code Helper") {
      if text.contains("--type=renderer") { return ("VS Code · вікно", "VS Code") }
      if text.contains("--type=gpu-process") { return ("VS Code · графіка", "VS Code") }
      if text.contains("extensionHost") || text.contains("--type=utility") {
        return ("VS Code · розширення", "VS Code")
      }
      return ("VS Code", "VS Code")
    }
    if name == "Telegram" { return ("Telegram", "Telegram") }
    if name.hasPrefix("com.apple") || name.hasPrefix("Apple") { return (name, "Системні") }

    return (name, nil)
  }

  /// Відомі порти: показуємо зміст, а не номер.
  static func portMeaning(_ port: UInt16) -> String? {
    switch port {
    case 3000: return "Next.js dev"
    case 3001: return "Next.js (запасний)"
    case 3100: return "Playwright rig"
    case 5432: return "PostgreSQL"
    case 6379: return "Redis"
    case 5555: return "Prisma Studio"
    case 6432: return "PgBouncer"
    case 8080, 8000: return "HTTP-сервер"
    case 9222: return "Chrome DevTools"
    case 5173: return "Vite"
    default: return nil
    }
  }
}
