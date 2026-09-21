import Combine
import Darwin
import Foundation
import SwiftUI

/// Координатор збору. Тут живе головний принцип додатка:
///
///   дешеве — у фоні, дороге — лише за кнопкою.
///
/// Дешеве (метрики ядра, список процесів із RSS і CPU) коштує 0.7 мс на цикл,
/// тож іде постійно. Дороге (аргументи всіх процесів, сканування портів,
/// дерево звʼязків) запускається або коли вікно відкрите, або коли людина
/// натиснула «оновити». Закрите вікно = крок 10 с і жодних зайвих обчислень:
/// у menu bar усе одно видно лише два числа.
@MainActor
final class Monitor: ObservableObject {

  @Published private(set) var snapshot = SystemSnapshot()
  @Published private(set) var processes: [ProcessInfo_] = []
  @Published private(set) var findings: [Finding] = []
  @Published private(set) var ports: [ListeningPort] = []
  @Published private(set) var lastPortScan: Date?
  @Published private(set) var lastDetailPass: Date?
  @Published var detailsOpen = false {
    didSet { restartTimer() }
  }

  /// Історія CPU за останні 60 замірів — лише в памʼяті, нічого не пишемо.
  @Published private(set) var cpuHistory: [Double] = []

  private let metrics = SystemMetrics()
  private let sampler = ProcessSampler()
  private var timer: Timer?

  /// Крок при відкритому вікні й при закритому.
  private let activeInterval: TimeInterval = 2
  private let idleInterval: TimeInterval = 10

  init() {
    tick(enrich: true)
    restartTimer()
  }

  private func restartTimer() {
    timer?.invalidate()
    let interval = detailsOpen ? activeInterval : idleInterval
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick(enrich: self?.detailsOpen ?? false) }
    }
    // Допуск дозволяє системі групувати пробудження з іншими таймерами —
    // менше виходів процесора зі сну, менше витрат батареї.
    timer.tolerance = interval * 0.3
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Один цикл. `enrich` вмикає дорогу частину: назви процесів з аргументів.
  private func tick(enrich: Bool) {
    snapshot = metrics.collect()
    cpuHistory.append(snapshot.cpuTotal)
    if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }

    var sampled = sampler.sample()
    snapshot.processCount = sampled.count + sampler.systemOnly
    snapshot.inspectableCount = sampled.count
    snapshot.threadCount = sampled.reduce(0) { $0 + $1.threads }

    if enrich {
      annotate(&sampled)
      findings = Findings.detect(processes: sampled)
      lastDetailPass = Date()
    } else {
      // Без розпізнавання лишаємо попередні назви, щоб список не «мигав».
      let previous = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
      for index in sampled.indices {
        if let old = previous[sampled[index].pid] {
          sampled[index].label = old.label
          sampled[index].group = old.group
          sampled[index].command = old.command
        }
      }
    }
    processes = sampled
  }

  /// Дороге: читаємо аргументи й даємо людські назви.
  ///
  /// Робимо це не для всіх 600 процесів, а лише для тих, які реально можуть
  /// потрапити на екран або у знахідки: помітні за памʼяттю чи процесором,
  /// або з упізнаваним іменем. Так дорога частина лишається дешевою.
  private func annotate(_ list: inout [ProcessInfo_]) {
    let interesting: Set<String> = [
      "node", "bun", "claude", "next-server", "postgres", "redis-server", "tsc", "tsserver",
      "vitest", "esbuild", "biome", "npm", "npx", "zsh", "sh",
    ]
    for index in list.indices {
      let proc = list[index]
      let notable =
        proc.rss > 150 * 1024 * 1024 || proc.cpu > 0.1
        || interesting.contains(where: { proc.name.hasPrefix($0) })
      guard notable else {
        let described = Identifier.describe(name: proc.name, command: nil, cwd: nil)
        list[index].label = described.label
        list[index].group = described.group
        continue
      }
      let command = ProcessSampler.commandLine(proc.pid)
      let cwd = ProcessSampler.workingDirectory(proc.pid)
      let described = Identifier.describe(name: proc.name, command: command, cwd: cwd)
      list[index].command = command
      list[index].label = described.label
      list[index].group = described.group
    }

    // Нащадки успадковують групу батька: MCP-сервери й оболонки, запущені
    // сесією Claude, мають складатись у ту саму групу, а не губитись.
    let byPid = Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
    for index in list.indices where list[index].group == nil {
      var parent = list[index].ppid
      var depth = 0
      while depth < 4, let ancestor = byPid[parent] {
        if let group = ancestor.group {
          list[index].group = group
          break
        }
        parent = ancestor.ppid
        depth += 1
      }
    }
  }

  // ── Дії на вимогу (кнопки) ───────────────────────────────────────────

  /// Сканування портів. Коштує ~2 мс, але змінюється рідко, тож тільки тут.
  func refreshPorts() {
    ports = PortScanner.scan(processes: processes)
    lastPortScan = Date()
  }

  /// Повний перерахунок з розпізнаванням — кнопка «оновити зараз».
  func refreshNow() {
    tick(enrich: true)
    refreshPorts()
  }

  /// Мʼяка зупинка (SIGTERM): процес встигає зберегтись і закрити зʼєднання.
  @discardableResult
  func terminate(_ pid: Int32) -> Bool {
    kill(pid, SIGTERM) == 0
  }

  /// Жорстка зупинка (SIGKILL) — коли мʼяка не спрацювала.
  @discardableResult
  func forceKill(_ pid: Int32) -> Bool {
    kill(pid, SIGKILL) == 0
  }

  func terminateAll(_ pids: [Int32]) {
    for pid in pids { terminate(pid) }
    // Даємо процесам секунду на коректне завершення, потім оновлюємо список.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.refreshNow()
    }
  }

  // ── Похідні дані для вікна ───────────────────────────────────────────

  /// Процеси, згорнуті в групи: 17 рядків Claude стають одним.
  struct Group: Identifiable {
    var id: String { name }
    let name: String
    let memory: UInt64
    let cpu: Double
    let members: [ProcessInfo_]
  }

  func groups(limit: Int = 8) -> [Group] {
    var buckets: [String: [ProcessInfo_]] = [:]
    for proc in processes {
      let key = proc.group ?? proc.label ?? proc.name
      buckets[key, default: []].append(proc)
    }
    return
      buckets
      .map { name, members in
        Group(
          name: name,
          memory: members.reduce(0) { $0 + $1.rss },
          cpu: members.reduce(0) { $0 + $1.cpu },
          members: members.sorted { $0.rss > $1.rss })
      }
      .sorted { $0.memory > $1.memory }
      .prefix(limit)
      .map { $0 }
  }

  var topByCPU: [ProcessInfo_] {
    processes.filter { $0.cpu > 0.02 }.sorted { $0.cpu > $1.cpu }.prefix(6).map { $0 }
  }
}
