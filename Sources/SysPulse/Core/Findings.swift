import Foundation

/// Знахідка: те, що варто побачити без пошуку очима.
struct Finding: Identifiable, Sendable {
  enum Kind: Sendable {
    case duplicates  // кілька копій того самого дев-сервера
    case stuck  // тримає ядро надто довго
    case idleSessions  // сесії Claude без активності
    case orphan  // батько помер
    case heavy  // група зайняла забагато памʼяті
  }
  let id: String
  let kind: Kind
  let title: String
  let detail: String
  let pids: [Int32]
  /// Наскільки це терміново: впливає лише на порядок, не на колір усього вікна.
  let severity: Int
}

/// Пошук проблем у знімку процесів.
///
/// Усі правила — чиста арифметика над уже зібраними даними, без додаткових
/// звернень до системи.
enum Findings {

  /// Процес, що тримає понад половину ядра довше за це, — підозрілий.
  static let stuckCPUThreshold = 0.5
  static let stuckRuntimeThreshold: TimeInterval = 3600 * 6
  /// Сесія Claude без помітного CPU довше за це вважається забутою.
  static let idleSessionThreshold: TimeInterval = 3600 * 8

  static func detect(processes: [ProcessInfo_]) -> [Finding] {
    var findings: [Finding] = []

    // ── Дублі дев-серверів ──────────────────────────────────────────────
    // Саме те, з чого все почалось: «бувало, що кілька копій next запущені».
    var byGroup: [String: [ProcessInfo_]] = [:]
    for proc in processes {
      guard let group = proc.group, group.hasPrefix("Next.js") || group.hasPrefix("Vitest") else {
        continue
      }
      byGroup[group, default: []].append(proc)
    }
    for (group, members) in byGroup where members.count > 1 {
      // Воркери білда — це нормально: у них спільний батько. Дублями
      // вважаємо лише незалежні процеси (різні батьки або батько вже помер).
      let roots = members.filter { member in !members.contains { $0.pid == member.ppid } }
      guard roots.count > 1 else { continue }
      let memory = roots.reduce(0) { $0 + $1.rss }
      findings.append(
        Finding(
          id: "dup-\(group)",
          kind: .duplicates,
          title: "\(roots.count) копії «\(group)»",
          detail:
            "Незалежні процеси, разом \(Format.bytes(memory)). Найстаріший працює \(Format.duration(roots.map(\.runtime).max() ?? 0)).",
          pids: roots.map(\.pid),
          severity: 3))
    }

    // ── Завислі: довго тримають процесор ────────────────────────────────
    for proc in processes
    where proc.cpu > stuckCPUThreshold && proc.runtime > stuckRuntimeThreshold {
      findings.append(
        Finding(
          id: "stuck-\(proc.pid)",
          kind: .stuck,
          title: "«\(proc.label ?? proc.name)» тримає \(Int(proc.cpu * 100))% ядра",
          detail:
            "Працює \(Format.duration(proc.runtime)) і весь цей час навантажує процесор. Найчастіше це зациклений або забутий процес.",
          pids: [proc.pid],
          severity: 4))
    }

    // ── Забуті сесії Claude ─────────────────────────────────────────────
    let claude = processes.filter { $0.group == "Claude Code" }
    let idle = claude.filter { $0.cpu < 0.02 && $0.runtime > idleSessionThreshold }
    if idle.count >= 3 {
      let memory = idle.reduce(0) { $0 + $1.rss }
      findings.append(
        Finding(
          id: "claude-idle",
          kind: .idleSessions,
          title: "\(idle.count) сесій Claude без активності",
          detail:
            "Разом тримають \(Format.bytes(memory)). Найстаріша відкрита \(Format.duration(idle.map(\.runtime).max() ?? 0)) тому.",
          pids: idle.map(\.pid),
          severity: 2))
    }

    // ── Сироти: батько помер ────────────────────────────────────────────
    let alive = Set(processes.map(\.pid))
    let orphans = processes.filter { proc in
      proc.ppid > 1 && !alive.contains(proc.ppid) && proc.rss > 100 * 1024 * 1024
    }
    if !orphans.isEmpty {
      findings.append(
        Finding(
          id: "orphans",
          kind: .orphan,
          title: "\(orphans.count) процесів без батька",
          detail:
            "Їх запустив процес, якого вже немає: \(orphans.prefix(3).map { $0.label ?? $0.name }.joined(separator: ", ")).",
          pids: orphans.map(\.pid),
          severity: 2))
    }

    // ── Група зайняла забагато памʼяті ──────────────────────────────────
    var groupMemory: [String: (UInt64, [Int32])] = [:]
    for proc in processes {
      guard let group = proc.group else { continue }
      var entry = groupMemory[group] ?? (0, [])
      entry.0 += proc.rss
      entry.1.append(proc.pid)
      groupMemory[group] = entry
    }
    for (group, entry) in groupMemory where entry.0 > 3 * 1024 * 1024 * 1024 {
      findings.append(
        Finding(
          id: "heavy-\(group)",
          kind: .heavy,
          title: "«\(group)» зайняв \(Format.bytes(entry.0))",
          detail: "\(entry.1.count) процесів однієї групи.",
          pids: entry.1,
          severity: 1))
    }

    return findings.sorted { $0.severity > $1.severity }
  }
}
