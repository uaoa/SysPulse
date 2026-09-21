import AppKit
import SwiftUI

/// Вікно з деталями. Відкривається кліком по menu bar.
///
/// Порядок блоків — за питанням, на яке людина відповідає найчастіше:
/// «усе гаразд?» → «хто винен?» → «що з портами?» → «що зупинити?».
struct DetailView: View {
  @ObservedObject var monitor: Monitor
  @State private var expanded: Set<String> = []
  @State private var showAllDetails = false
  @State private var confirmKill: Finding?

  private var verdict: (text: String, level: Int) { Format.verdict(monitor.snapshot) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          findingsSection
          resourcesSection
          groupsSection
          portsSection
        }
        .padding(12)
      }
      Divider()
      footer
    }
    // MenuBarExtra(.window) не нав'язує розміру: без явної висоти ScrollView
    // отримує нуль і вміст просто не видно. Тому висота задана прямо тут.
    .frame(width: 380, height: 600)
    .onAppear {
      monitor.detailsOpen = true
      // Один скан портів при відкритті: 2 мс — дешевше за будь-яке очікування
      // від користувача. Далі лише за кнопкою «оновити».
      if monitor.ports.isEmpty { monitor.refreshPorts() }
    }
    .onDisappear { monitor.detailsOpen = false }
  }

  // ── Шапка: вердикт словами ────────────────────────────────────────────

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Circle()
          .fill(Palette.level(verdict.level))
          .frame(width: 8, height: 8)
        Text(verdict.text)
          .font(.system(size: 12, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button {
          showAllDetails.toggle()
        } label: {
          Image(systemName: showAllDetails ? "info.circle.fill" : "info.circle")
            .font(.system(size: 13))
            .foregroundStyle(showAllDetails ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showAllDetails ? "Сховати деталі" : "Більше деталей")
      }
      HStack(spacing: 10) {
        Label(
          "\(monitor.snapshot.processCount) процесів", systemImage: "square.stack.3d.up"
        )
        .help(
          "З них \(monitor.snapshot.inspectableCount) доступні для огляду; решта — системні служби, які macOS не показує без адмінських прав."
        )
        Label("\(monitor.snapshot.threadCount) потоків", systemImage: "arrow.triangle.branch")
        Spacer()
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  // ── Підвал: керування самим додатком ──────────────────────────────────

  private var footer: some View {
    HStack(spacing: 8) {
      Toggle("Запускати при вході", isOn: launchBinding)
        .toggleStyle(.checkbox)
        .font(.system(size: 10))
      Spacer()
      ActionButton(title: "Оновити") { monitor.refreshNow() }
      ActionButton(title: "Вийти") { NSApp.terminate(nil) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var launchBinding: Binding<Bool> {
    Binding(
      get: { LaunchAtLogin.isEnabled },
      set: { $0 ? LaunchAtLogin.enable() : LaunchAtLogin.disable() })
  }

  // ── Знахідки ──────────────────────────────────────────────────────────

  @ViewBuilder
  private var findingsSection: some View {
    if !monitor.findings.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("Варто подивитись")
        ForEach(monitor.findings) { finding in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: icon(for: finding.kind))
                .font(.system(size: 11))
                .foregroundStyle(Palette.level(min(3, finding.severity)))
                .frame(width: 14)
              VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                  .font(.system(size: 11, weight: .medium))
                Text(finding.detail)
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 4)
            }
            HStack(spacing: 6) {
              Spacer()
              if showAllDetails {
                Text(finding.pids.map(String.init).joined(separator: ", "))
                  .font(.system(size: 9, design: .monospaced))
                  .foregroundStyle(.tertiary)
              }
              ActionButton(
                title: finding.pids.count > 1
                  ? "Зупинити всі (\(finding.pids.count))" : "Зупинити",
                destructive: true
              ) {
                confirmKill = finding
              }
            }
          }
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04))
          )
        }
      }
      .alert(item: $confirmKill) { finding in
        Alert(
          title: Text("Зупинити \(finding.pids.count) процес(ів)?"),
          message: Text(
            "\(finding.title)\n\nСпершу надішлемо мʼякий сигнал завершення — процес встигне зберегти стан."
          ),
          primaryButton: .destructive(Text("Зупинити")) {
            monitor.terminateAll(finding.pids)
          },
          secondaryButton: .cancel(Text("Скасувати")))
      }
    }
  }

  private func icon(for kind: Finding.Kind) -> String {
    switch kind {
    case .duplicates: return "doc.on.doc"
    case .stuck: return "exclamationmark.triangle"
    case .idleSessions: return "moon.zzz"
    case .orphan: return "questionmark.circle"
    case .heavy: return "scalemass"
    }
  }

  // ── Ресурси ───────────────────────────────────────────────────────────

  private var resourcesSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("Ресурси")

      MetricRow(
        title: "Процесор",
        value: Format.percent(monitor.snapshot.cpuTotal),
        fraction: monitor.snapshot.cpuTotal,
        hint: queueHint)

      if showAllDetails, !monitor.snapshot.perCore.isEmpty {
        CoreGrid(
          values: monitor.snapshot.perCore,
          performanceCores: monitor.snapshot.performanceCores)
        Text(
          "P-ядра \(Format.percent(monitor.snapshot.cpuPerformance)) · E-ядра \(Format.percent(monitor.snapshot.cpuEfficiency))"
        )
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
      }

      MetricRow(
        title: "Памʼять",
        value:
          "\(Format.bytes(monitor.snapshot.memUsed)) з \(Format.bytes(monitor.snapshot.memTotal))",
        fraction: monitor.snapshot.memPressure,
        hint: showAllDetails
          ? "стиснуто \(Format.bytes(monitor.snapshot.memCompressed)) · ядро \(Format.bytes(monitor.snapshot.memWired)) · кеш файлів \(Format.bytes(monitor.snapshot.memCached))"
          : nil)

      if monitor.snapshot.swapTotal > 0 {
        MetricRow(
          title: "Своп",
          value:
            "\(Format.bytes(monitor.snapshot.swapUsed)) з \(Format.bytes(monitor.snapshot.swapTotal))",
          fraction: monitor.snapshot.swapPressure,
          hint: monitor.snapshot.swapOutsPerSec > 10
            ? "вивантаження просто зараз: \(Int(monitor.snapshot.swapOutsPerSec)) сторінок/с"
            : (showAllDetails ? "зайнятий своп сам по собі не гальмує — важливий темп вивантаження" : nil))
      }
    }
  }

  private var queueHint: String {
    let load = monitor.snapshot.loadAverage.0
    let cores = max(1, monitor.snapshot.perCore.count)
    let text = String(format: "черга %.1f на %d ядер", load, cores)
    if monitor.snapshot.loadPerCore > 1.2 {
      return text + " — процеси чекають на процесор"
    }
    return text
  }

  // ── Хто скільки зайняв ────────────────────────────────────────────────

  private var groupsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionTitle("Хто займає памʼять")
      ForEach(monitor.groups()) { group in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Button {
              if expanded.contains(group.name) {
                expanded.remove(group.name)
              } else {
                expanded.insert(group.name)
              }
            } label: {
              Image(
                systemName: expanded.contains(group.name) ? "chevron.down" : "chevron.right"
              )
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.tertiary)
              .frame(width: 10)
            }
            .buttonStyle(.plain)
            .disabled(group.members.count == 1)
            .opacity(group.members.count == 1 ? 0 : 1)

            Text(group.name)
              .font(.system(size: 11))
              .lineLimit(1)
            if group.members.count > 1 {
              Text("×\(group.members.count)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if group.cpu > 0.05 {
              Text(Format.percent(group.cpu))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(group.cpu > 0.8 ? Color.orange : Color.secondary)
            }
            Text(Format.bytes(group.memory))
              .font(.system(size: 10, weight: .medium))
              .monospacedDigit()
          }

          if expanded.contains(group.name) {
            ForEach(group.members.prefix(12)) { member in
              processRow(member)
            }
            if group.members.count > 1 {
              HStack {
                Spacer()
                ActionButton(title: "Зупинити всю групу", destructive: true) {
                  confirmKill = Finding(
                    id: "group-\(group.name)",
                    kind: .duplicates,
                    title: group.name,
                    detail: "\(group.members.count) процесів, \(Format.bytes(group.memory))",
                    pids: group.members.map(\.pid),
                    severity: 2)
                }
              }
            }
          }
        }
      }
    }
  }

  private func processRow(_ member: ProcessInfo_) -> some View {
    HStack(spacing: 6) {
      Text(String(member.pid))
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 42, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(member.label ?? member.name)
          .font(.system(size: 10))
          .lineLimit(1)
        if showAllDetails {
          Text("\(Format.duration(member.runtime)) · \(member.threads) потоків")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 4)
      Text(Format.bytes(member.rss))
        .font(.system(size: 9))
        .monospacedDigit()
        .foregroundStyle(.secondary)
      ActionButton(title: "×", destructive: true) {
        monitor.terminate(member.pid)
      }
    }
    .padding(.leading, 16)
  }

  // ── Порти ─────────────────────────────────────────────────────────────

  private var portsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        sectionTitle("Порти")
        Spacer()
        // Сканування портів — окрема кнопка: воно дорожче за решту циклу,
        // а порти змінюються рідко.
        ActionButton(title: monitor.ports.isEmpty ? "Показати" : "Оновити") {
          monitor.refreshPorts()
        }
      }
      if monitor.ports.isEmpty {
        Text("Ніхто не слухає портів.")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      } else {
        ForEach(monitor.ports) { port in
          HStack(spacing: 6) {
            Text(":\(String(port.port))")
              .font(.system(size: 10, weight: .medium, design: .monospaced))
              .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
              Text(port.meaning ?? port.label ?? port.processName)
                .font(.system(size: 10))
                .lineLimit(1)
              if showAllDetails {
                Text(
                  "\(port.label ?? port.processName) · pid \(port.pid) · \(Format.duration(port.runtime))\(port.loopbackOnly ? " · лише локально" : "")"
                )
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
              }
            }
            Spacer(minLength: 4)
            ActionButton(title: "Звільнити", destructive: true) {
              monitor.terminate(port.pid)
            }
          }
        }
      }
    }
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.tertiary)
      .tracking(0.6)
  }
}
