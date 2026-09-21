import Darwin
import Foundation

/// Один процес у знімку.
struct ProcessInfo_: Identifiable, Sendable {
  var id: Int32 { pid }
  let pid: Int32
  let ppid: Int32
  let name: String
  /// Скільки памʼяті процес реально тримає в RAM.
  let rss: UInt64
  /// Частка ядра за час від попереднього знімка (0…1 на ядро, може бути >1).
  var cpu: Double
  let threads: Int
  let started: Date
  /// Аргументи читаються ЛИШЕ на вимогу (кнопка «деталі»): це найдорожча
  /// частина збору, ~0.1 мс на процес, і в фоні вона не потрібна.
  var command: String?
  /// Людська назва: «Claude Code · AOA», «next dev · AOA», «Chrome».
  var label: String?
  /// До якої групи належить (для згортання 17 рядків Claude в один).
  var group: String?
  /// Порти, які процес слухає.
  var ports: [UInt16] = []

  var runtime: TimeInterval { Date().timeIntervalSince(started) }
}

/// Збирач процесів.
///
/// Один `sysctl(KERN_PROC_ALL)` дає всі процеси разом із часом старту й ppid,
/// далі по кожному `proc_pidinfo` за RSS і тактами процесора. Замір на цій
/// машині: 602 процеси за 0.7 мс, тобто 0.037% ядра при кроці 2 с. Для
/// порівняння, один запуск `ps` коштує дорожче за двісті таких циклів.
final class ProcessSampler {
  /// Попередні такти процесора по кожному pid: CPU — це різниця між замірами.
  private var previousCPU: [Int32: (ticks: UInt64, time: Date)] = [:]

  /// Скільки процесів система не дала оглянути (служби root) — для чесного
  /// лічильника у вікні.
  private(set) var systemOnly = 0

  func sample() -> [ProcessInfo_] {
    systemOnly = 0
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var length = 0
    guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] }

    let capacity = length / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    guard sysctl(&mib, 4, &procs, &length, nil, 0) == 0 else { return [] }
    let count = min(capacity, length / MemoryLayout<kinfo_proc>.stride)

    let now = Date()
    var result: [ProcessInfo_] = []
    result.reserveCapacity(count)
    var seen = Set<Int32>(minimumCapacity: count)

    for index in 0..<count {
      let proc = procs[index]
      let pid = proc.kp_proc.p_pid
      guard pid > 0 else { continue }
      seen.insert(pid)

      var task = proc_taskallinfo()
      let size = proc_pidinfo(
        pid, PROC_PIDTASKALLINFO, 0, &task, Int32(MemoryLayout<proc_taskallinfo>.size))
      // Системні служби від root деталей не віддають (~190 процесів з 660).
      // Це не помилка: своїх процесів, заради яких додаток і потрібен, це не
      // стосується. Але рахувати їх треба, інакше «процесів у системі» бреше.
      guard size > 0 else {
        systemOnly += 1
        continue
      }

      // Такти процесора: user + system, у наносекундах через mach-одиниці.
      let ticks = task.ptinfo.pti_total_user &+ task.ptinfo.pti_total_system
      var cpu = 0.0
      if let previous = previousCPU[pid] {
        let elapsed = now.timeIntervalSince(previous.time)
        if elapsed > 0.05, ticks >= previous.ticks {
          cpu = Double(ticks - previous.ticks) / (elapsed * 1_000_000_000)
        }
      }
      previousCPU[pid] = (ticks, now)

      let comm = proc.kp_proc.p_comm
      let name = withUnsafePointer(to: comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: comm)) {
          String(cString: $0)
        }
      }
      let start = Date(
        timeIntervalSince1970: Double(proc.kp_proc.p_un.__p_starttime.tv_sec)
          + Double(proc.kp_proc.p_un.__p_starttime.tv_usec) / 1_000_000)

      result.append(
        ProcessInfo_(
          pid: pid,
          ppid: proc.kp_eproc.e_ppid,
          name: name,
          rss: task.ptinfo.pti_resident_size,
          cpu: cpu,
          threads: Int(task.ptinfo.pti_threadnum),
          started: start,
          command: nil,
          label: nil,
          group: nil))
    }

    // Прибираємо померлі процеси, щоб словник не ріс нескінченно.
    if previousCPU.count > seen.count * 2 {
      previousCPU = previousCPU.filter { seen.contains($0.key) }
    }
    return result
  }

  /// Повний рядок запуску процесу. Дорого (`KERN_PROCARGS2` копіює буфер),
  /// тому викликається лише для процесів, які реально показуємо, або на вимогу.
  static func commandLine(_ pid: Int32) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var length = 0
    guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }

    let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var parts: [String] = []
    var current: [UInt8] = []
    for byte in buffer[4..<length] {
      if byte == 0 {
        if !current.isEmpty {
          parts.append(String(decoding: current, as: UTF8.self))
          current = []
        }
      } else {
        current.append(byte)
      }
    }
    guard !parts.isEmpty else { return nil }
    // Перший елемент — шлях до бінарника, далі argv; змінні середовища після
    // argc відкидаємо: там можуть бути токени, і показувати їх не можна.
    let argv = Array(parts.prefix(max(1, argc)))
    return argv.joined(separator: " ")
  }

  /// Робоча тека процесу. Для чужих процесів ядро її не віддає без окремих
  /// прав, тому це лише підказка там, де вона доступна (власні процеси).
  static func workingDirectory(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = proc_pidinfo(
      pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
    guard size > 0 else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
  }
}
