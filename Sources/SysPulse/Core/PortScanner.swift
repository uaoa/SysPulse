import Darwin
import Foundation

/// Порт, який хтось слухає.
struct ListeningPort: Identifiable, Sendable {
  var id: String { "\(pid):\(port)" }
  let port: UInt16
  let pid: Int32
  let processName: String
  var label: String?
  /// Пояснення за номером порту («Next.js dev»), якщо порт відомий.
  var meaning: String?
  var runtime: TimeInterval = 0
  var loopbackOnly: Bool = false
}

/// Сканер портів на заміну `lsof -iTCP -sTCP:LISTEN`.
///
/// `lsof` обходить таблиці дескрипторів усієї системи й коштує сотні
/// мілісекунд. Тут ми питаємо ядро напряму: список дескрипторів процесу і
/// стан сокета. Замір на цій машині: усі 600 процесів за 2 мс.
///
/// Викликається РІДШЕ за метрики (порти змінюються повільно), а на вимогу
/// користувача оновлюється миттєво.
enum PortScanner {

  static func scan(processes: [ProcessInfo_]) -> [ListeningPort] {
    var result: [ListeningPort] = []
    var seen = Set<String>()

    for proc in processes {
      let bufferSize = proc_pidinfo(proc.pid, PROC_PIDLISTFDS, 0, nil, 0)
      guard bufferSize > 0 else { continue }
      let capacity = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
      var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
      let got = proc_pidinfo(proc.pid, PROC_PIDLISTFDS, 0, &descriptors, bufferSize)
      guard got > 0 else { continue }

      for index in 0..<min(capacity, Int(got) / MemoryLayout<proc_fdinfo>.stride) {
        let descriptor = descriptors[index]
        guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }

        var socketInfo = socket_fdinfo()
        let size = proc_pidfdinfo(
          proc.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo,
          Int32(MemoryLayout<socket_fdinfo>.size))
        guard size > 0, socketInfo.psi.soi_kind == SOCKINFO_TCP else { continue }

        let tcp = socketInfo.psi.soi_proto.pri_tcp
        // 1 = TCPS_LISTEN: саме «слухає», а не встановлене зʼєднання.
        guard tcp.tcpsi_state == 1 else { continue }

        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        guard port > 0 else { continue }
        let key = "\(proc.pid):\(port)"
        guard !seen.contains(key) else { continue }
        seen.insert(key)

        // Чи слухає лише локально (127.0.0.1), чи на всіх інтерфейсах.
        let loopback = tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == 0x0100_007F

        result.append(
          ListeningPort(
            port: port,
            pid: proc.pid,
            processName: proc.name,
            label: proc.label,
            meaning: Identifier.portMeaning(port),
            runtime: proc.runtime,
            loopbackOnly: loopback))
      }
    }
    return result.sorted { $0.port < $1.port }
  }
}
