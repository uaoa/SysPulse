import Darwin
import Foundation

/// Метрики машини: процесор, памʼять, своп, черга до процесора.
///
/// Усе читається прямими викликами до ядра (`host_statistics64`, `sysctl`,
/// `getloadavg`). Жодного `top`, `ps` чи `vm_stat`: запуск зовнішнього процесу
/// коштує одиниці мілісекунд і сам стає навантаженням, якого ми й уникаємо.
/// Повний збір метрик тут — десятки мікросекунд.
struct SystemSnapshot: Sendable {
  var cpuTotal: Double = 0  // 0…1, усі ядра разом
  var perCore: [Double] = []
  var performanceCores: Int = 0
  /// Навантаження P-ядер окремо: саме вони визначають, чи «тягне» машина.
  var cpuPerformance: Double = 0
  var cpuEfficiency: Double = 0

  var memUsed: UInt64 = 0
  var memTotal: UInt64 = 0
  var memCompressed: UInt64 = 0
  var memWired: UInt64 = 0
  var memCached: UInt64 = 0

  var swapUsed: UInt64 = 0
  var swapTotal: UInt64 = 0
  /// Скільки сторінок пішло на диск від попереднього знімка. Саме це, а не
  /// «свопу зайнято», означає, що система гальмує прямо зараз: зайнятий своп
  /// може бути давнім і не заважати.
  var swapOutsPerSec: Double = 0

  var loadAverage: (Double, Double, Double) = (0, 0, 0)
  var processCount: Int = 0
  /// Скільки з них ми можемо оглянути (решта — служби root).
  var inspectableCount: Int = 0
  var threadCount: Int = 0

  var memPressure: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) }
  var swapPressure: Double { swapTotal == 0 ? 0 : Double(swapUsed) / Double(swapTotal) }
  /// Черга на ядро: 1.0 = процесор рівно завантажений, більше — процеси чекають.
  var loadPerCore: Double {
    perCore.isEmpty ? 0 : loadAverage.0 / Double(perCore.count)
  }
}

/// Збирач метрик. Тримає попередній знімок лічильників, бо всі вони
/// накопичувальні: миттєве значення — це різниця між двома замірами.
final class SystemMetrics {
  private var previousTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
  private var previousSwapOuts: UInt64 = 0
  private var previousSwapTime: Date?
  private let coreCount: Int
  private let perfCoreCount: Int
  private let pageSize: UInt64
  private let memTotal: UInt64

  init() {
    coreCount = Self.sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
    // На Apple Silicon перші ядра — продуктивні (P), далі енергоефективні (E).
    perfCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? coreCount
    var ps: vm_size_t = 0
    host_page_size(mach_host_self(), &ps)
    pageSize = UInt64(ps)
    memTotal = UInt64(Self.sysctlInt("hw.memsize") ?? 0)
  }

  private static func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
  }

  func collect() -> SystemSnapshot {
    var snap = SystemSnapshot()
    snap.performanceCores = perfCoreCount
    snap.memTotal = memTotal
    collectCPU(into: &snap)
    collectMemory(into: &snap)
    collectSwap(into: &snap)

    var load = [Double](repeating: 0, count: 3)
    if getloadavg(&load, 3) == 3 {
      snap.loadAverage = (load[0], load[1], load[2])
    }
    return snap
  }

  private func collectCPU(into snap: inout SystemSnapshot) {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard
      host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        == KERN_SUCCESS,
      let info
    else { return }
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
    }

    var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    current.reserveCapacity(Int(count))
    for core in 0..<Int(count) {
      let base = core * Int(CPU_STATE_MAX)
      current.append(
        (
          user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
          system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
          idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
          nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
        ))
    }

    defer { previousTicks = current }
    guard previousTicks.count == current.count else {
      snap.perCore = Array(repeating: 0, count: current.count)
      return
    }

    var busySum = 0.0, perfSum = 0.0, effSum = 0.0
    var perfN = 0, effN = 0
    for (index, now) in current.enumerated() {
      let before = previousTicks[index]
      // Лічильники 32-бітні й переповнюються — віднімаємо з урахуванням цього.
      let user = now.user &- before.user
      let system = now.system &- before.system
      let idle = now.idle &- before.idle
      let nice = now.nice &- before.nice
      let total = Double(user) + Double(system) + Double(idle) + Double(nice)
      let busy = total > 0 ? (Double(user) + Double(system) + Double(nice)) / total : 0
      snap.perCore.append(busy)
      busySum += busy
      if index < perfCoreCount {
        perfSum += busy
        perfN += 1
      } else {
        effSum += busy
        effN += 1
      }
    }
    snap.cpuTotal = current.isEmpty ? 0 : busySum / Double(current.count)
    snap.cpuPerformance = perfN > 0 ? perfSum / Double(perfN) : 0
    snap.cpuEfficiency = effN > 0 ? effSum / Double(effN) : 0
  }

  private func collectMemory(into snap: inout SystemSnapshot) {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return }

    snap.memWired = UInt64(stats.wire_count) * pageSize
    snap.memCompressed = UInt64(stats.compressor_page_count) * pageSize
    snap.memCached = UInt64(stats.external_page_count) * pageSize
    // «Зайнято» рахуємо як у Activity Monitor: активні + стиснуті + wired,
    // без файлового кешу — він віддається системі на першу вимогу.
    let appMemory = UInt64(stats.internal_page_count - stats.purgeable_count) * pageSize
    snap.memUsed = appMemory + snap.memWired + snap.memCompressed
  }

  private func collectSwap(into snap: inout SystemSnapshot) {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
      snap.swapUsed = usage.xsu_used
      snap.swapTotal = usage.xsu_total
    }

    // Темп свопінгу: різниця лічильника сторінок, вивантажених на диск.
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard ok == KERN_SUCCESS else { return }
    let now = Date()
    let swapOuts = stats.swapouts
    if let previousTime = previousSwapTime, swapOuts >= previousSwapOuts {
      let elapsed = now.timeIntervalSince(previousTime)
      if elapsed > 0.1 {
        snap.swapOutsPerSec = Double(swapOuts - previousSwapOuts) / elapsed
      }
    }
    previousSwapOuts = swapOuts
    previousSwapTime = now
  }
}
