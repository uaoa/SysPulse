import Foundation

/// Безпечна оптимізація: звільнити те, що вже нікому не потрібне.
///
/// Свідомо НЕ робимо того, що роблять «прискорювачі» на кшталт CleanMyMac:
/// не чистимо RAM (`purge` викидає корисний кеш і потребує root — система
/// керує памʼяттю краще за нас), не чіпаємо файли на диску, не вимикаємо
/// служб. Усе, що тут відбувається, оборотне: зупинений dev-сервер
/// піднімається однією командою.
///
/// Кандидати беремо лише з уже зібраних даних, тож підбір коштує нуль.
enum Optimizer {

  /// Одна пропозиція: що зупинити й чому.
  struct Candidate: Identifiable, Sendable {
    let id: String
    let title: String
    /// Чому це безпечно зупинити — головне, що людина має прочитати.
    let reason: String
    let pids: [Int32]
    /// Скільки памʼяті звільниться.
    let memory: UInt64
    /// Чи позначено для зупинки. Ризиковіші пункти знято за замовчуванням.
    var selected: Bool
  }

  /// Скільки має простояти без діла dev-сервер, щоб вважати його забутим.
  static let staleServerThreshold: TimeInterval = 3600 * 4
  /// Сесія Claude без активності довше за це — кандидат на закриття.
  static let idleSessionThreshold: TimeInterval = 3600 * 8

  /// Підбір кандидатів зі знімка.
  ///
  /// `findings` дають те, що вже визнано проблемою; додаємо до них забуті
  /// dev-сервери й мертві порти, яких у findings немає.
  static func candidates(
    processes: [ProcessInfo_], findings: [Finding], ports: [ListeningPort]
  ) -> [Candidate] {
    var result: [Candidate] = []
    var claimed = Set<Int32>()

    // ── 1. Дублікати дев-серверів: найбезпечніше, що тут є ──────────────
    // Друга копія next dev нічого не обслуговує — порт зайняла перша.
    for finding in findings where finding.kind == .duplicates {
      let memory = memoryOf(finding.pids, in: processes)
      result.append(
        Candidate(
          id: finding.id,
          title: finding.title,
          reason:
            "Порт тримає лише одна копія — решта працюють намарно. Зупинка не зачепить той сервер, яким ви користуєтесь.",
          pids: finding.pids,
          memory: memory,
          selected: true))
      claimed.formUnion(finding.pids)
    }

    // ── 2. Процеси без батька ───────────────────────────────────────────
    // Термінал, який їх запустив, закрито: до них уже ніхто не звернеться.
    for finding in findings where finding.kind == .orphan {
      let pids = finding.pids.filter { !claimed.contains($0) }
      guard !pids.isEmpty else { continue }
      result.append(
        Candidate(
          id: finding.id,
          title: finding.title,
          reason:
            "Процес, який їх запустив, уже завершився. Зазвичай це залишки закритого терміналу.",
          pids: pids,
          memory: memoryOf(pids, in: processes),
          selected: true))
      claimed.formUnion(pids)
    }

    // ── 3. Забуті dev-сервери ───────────────────────────────────────────
    // Працює півдня, процесор не чіпає — швидше за все, проєкт давно закрито.
    let stale = processes.filter { proc in
      guard !claimed.contains(proc.pid), let group = proc.group else { return false }
      let isDevServer =
        group.hasPrefix("Next.js") || group.hasPrefix("Vitest") || group.hasPrefix("Vite")
      return isDevServer && proc.cpu < 0.02 && proc.runtime > staleServerThreshold
    }
    for proc in stale {
      result.append(
        Candidate(
          id: "stale-\(proc.pid)",
          title: proc.label ?? proc.name,
          reason:
            "Працює \(Format.duration(proc.runtime)) і весь цей час не навантажує процесор — схоже, проєкт уже закрито.",
          pids: [proc.pid],
          memory: proc.rss,
          selected: true))
      claimed.insert(proc.pid)
    }

    // ── 4. Забуті сесії Claude ──────────────────────────────────────────
    // Знято за замовчуванням: у сесії може лежати незбережений контекст.
    for finding in findings where finding.kind == .idleSessions {
      let pids = finding.pids.filter { !claimed.contains($0) }
      guard !pids.isEmpty else { continue }
      result.append(
        Candidate(
          id: finding.id,
          title: finding.title,
          reason:
            "Давно без активності. Перевірте, чи не лишилось у них потрібного — тому позначку знято.",
          pids: pids,
          memory: memoryOf(pids, in: processes),
          selected: false))
      claimed.formUnion(pids)
    }

    // ── 5. Зависші процеси ──────────────────────────────────────────────
    // Знято за замовчуванням: високий CPU буває і в чесної довгої роботи.
    for finding in findings where finding.kind == .stuck {
      let pids = finding.pids.filter { !claimed.contains($0) }
      guard !pids.isEmpty else { continue }
      result.append(
        Candidate(
          id: finding.id,
          title: finding.title,
          reason:
            "Схоже на зациклення, але так само виглядає й довга чесна робота — перевірте перед зупинкою.",
          pids: pids,
          memory: memoryOf(pids, in: processes),
          selected: false))
      claimed.formUnion(pids)
    }

    // Найбільша вигода — угорі.
    return result.sorted { $0.memory > $1.memory }
  }

  private static func memoryOf(_ pids: [Int32], in processes: [ProcessInfo_]) -> UInt64 {
    let set = Set(pids)
    return processes.filter { set.contains($0.pid) }.reduce(0) { $0 + $1.rss }
  }
}
