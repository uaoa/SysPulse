import AppKit
import SwiftUI

/// Вікно з деталями. Відкривається кліком по menu bar.
///
/// Порядок блоків — за питанням, на яке людина відповідає найчастіше:
/// «усе гаразд?» → «хто винен?» → «що з портами?» → «що зупинити?».
struct DetailView: View {
  @ObservedObject var monitor: Monitor
  @ObservedObject var settings: Settings
  @State private var expanded: Set<String> = []
  @State private var showAllDetails = false
  @State private var confirmKill: Finding?
  /// Непорожній список = відкрита панель оптимізації. Тримаємо копію
  /// кандидатів, бо позначки редагуються, а знімок під ними оновлюється.
  @State private var optimizing: [Optimizer.Candidate]?
  @State private var showSettings = false

  private var verdict: (text: String, level: Int) { Format.verdict(monitor.snapshot) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if showSettings { settingsSection }
          findingsSection
          resourcesSection
          sessionsSection
          groupsSection
          tabsSection
          portsSection
        }
        .padding(12)
      }
      Divider()
      footer
    }
    // Підтвердження — накладкою всередині попапу, а не .alert(). Попап
    // MenuBarExtra — це NSPanel, який закривається, втрачаючи фокус: окреме
    // вікно алерту забирає фокус, попап зникає разом із цим View, і діалог
    // залишається невидимим, але незакритим — клік нікуди не доходить.
    .overlay {
      if let finding = confirmKill {
        confirmSheet(finding)
      } else if optimizing != nil {
        optimizeSheet
      }
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
      Button {
        showSettings.toggle()
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 12))
          .foregroundStyle(showSettings ? Color.accentColor : Color.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Налаштування")

      ActionButton(title: "Прибрати зайве") {
        monitor.refreshNow()
        optimizing = monitor.optimizerCandidates
      }
      Spacer()
      ActionButton(title: "Оновити") { monitor.refreshNow() }
      ActionButton(title: "Вийти") { NSApp.terminate(nil) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // ── Налаштування ──────────────────────────────────────────────────────

  private var settingsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionTitle("Налаштування")
      VStack(alignment: .leading, spacing: 6) {
        Text("Показувати в menu bar")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Picker("", selection: $settings.menuBarMode) {
          ForEach(MenuBarMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Toggle("Запускати при вході", isOn: launchBinding)
          .toggleStyle(.checkbox)
          .font(.system(size: 10))

        Divider().padding(.vertical, 2)

        // Назви сесій Claude читаються з її власних журналів і дозволу не
        // потребують. Accessibility потрібен лише для заголовків вікон інших
        // застосунків — без нього список просто менш докладний.
        HStack(spacing: 6) {
          Text(
            WindowContext.isAuthorized
              ? "Заголовки вікон доступні"
              : "Дозвольте доступ, щоб бачити заголовки вікон застосунків"
          )
          .font(.system(size: 10))
          .foregroundStyle(WindowContext.isAuthorized ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          if !WindowContext.isAuthorized {
            ActionButton(title: "Дозволити") { monitor.requestWindowAccess() }
          }
        }
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }
  }

  // ── Оптимізація ───────────────────────────────────────────────────────

  /// Панель «прибрати зайве»: спершу показуємо, що саме буде зупинено, і лише
  /// потім діємо. Кнопки без списку тут бути не може — людина має бачити, що
  /// зникне з її машини.
  @ViewBuilder
  private var optimizeSheet: some View {
    ZStack {
      Rectangle()
        .fill(Color.black.opacity(0.28))
        .onTapGesture { optimizing = nil }

      VStack(alignment: .leading, spacing: 10) {
        Text("Прибрати зайве")
          .font(.system(size: 13, weight: .semibold))

        if let candidates = optimizing, candidates.isEmpty {
          Text("Нічого зайвого не знайшлось — система вже в порядку.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Усе тут зупиняється мʼяко і піднімається назад однією командою.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(Array((optimizing ?? []).enumerated()), id: \.element.id) { index, item in
                candidateRow(item, index: index)
              }
            }
          }
          .frame(maxHeight: 280)

          Divider()
          HStack {
            Text(selectionSummary)
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
            Spacer()
          }
        }

        HStack(spacing: 8) {
          Spacer()
          ActionButton(title: "Скасувати") { optimizing = nil }
          if let candidates = optimizing, !candidates.isEmpty {
            ActionButton(title: "Зупинити позначене", destructive: true) {
              monitor.optimize(candidates)
              optimizing = nil
            }
          }
        }
      }
      .padding(14)
      .frame(width: 330, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(.regularMaterial)
          .shadow(radius: 12, y: 4)
      )
    }
    .ignoresSafeArea()
  }

  private func candidateRow(_ item: Optimizer.Candidate, index: Int) -> some View {
    HStack(alignment: .top, spacing: 7) {
      Toggle(
        "",
        isOn: Binding(
          get: { optimizing?[index].selected ?? false },
          set: { optimizing?[index].selected = $0 })
      )
      .toggleStyle(.checkbox)
      .labelsHidden()

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(item.title)
            .font(.system(size: 11, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          Text(Format.bytes(item.memory))
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Text(item.reason)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var selectionSummary: String {
    let selected = (optimizing ?? []).filter(\.selected)
    guard !selected.isEmpty else { return "Нічого не позначено." }
    let memory = selected.reduce(0) { $0 + $1.memory }
    let count = selected.reduce(0) { $0 + $1.pids.count }
    return "Буде зупинено \(count) процес(ів), звільниться \(Format.bytes(memory))."
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
    }
  }

  // ── Підтвердження зупинки ─────────────────────────────────────────────

  /// Накладка замість системного алерту: живе в тому ж вікні, тому попап
  /// не втрачає фокус і не закривається на півдорозі.
  private func confirmSheet(_ finding: Finding) -> some View {
    ZStack {
      // Тло-заглушка: клік поза картку = скасування, як у звичайного діалогу.
      Rectangle()
        .fill(Color.black.opacity(0.28))
        .onTapGesture { confirmKill = nil }

      VStack(alignment: .leading, spacing: 10) {
        Text("Зупинити \(finding.pids.count) процес(ів)?")
          .font(.system(size: 12, weight: .semibold))
        Text(finding.title)
          .font(.system(size: 11))
          .fixedSize(horizontal: false, vertical: true)
        Text("Спершу надішлемо мʼякий сигнал завершення — процес встигне зберегти стан.")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Spacer()
          ActionButton(title: "Скасувати") { confirmKill = nil }
          ActionButton(title: "Зупинити", destructive: true) {
            monitor.terminateAll(finding.pids)
            confirmKill = nil
          }
        }
      }
      .padding(14)
      .frame(width: 300, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(.regularMaterial)
          .shadow(radius: 12, y: 4)
      )
    }
    .ignoresSafeArea()
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
      HStack {
        sectionTitle("Хто займає памʼять")
        Spacer()
        // Окрема кнопка, бо читання заголовків ходить по IPC у кожен
        // застосунок: дешевше за скан портів, але не для фонового циклу.
        ActionButton(title: monitor.lastContextPass == nil ? "Що відкрито" : "Оновити контекст") {
          monitor.refreshContext()
        }
        .help("Показати назви сесій Claude, вкладок Chrome і заголовки вікон")
      }
      ForEach(monitor.groups()) { group in
        VStack(alignment: .leading, spacing: 4) {
          // Ціль для кліку — увесь рядок, а не стрілка в десять пікселів.
          Button {
            guard group.members.count > 1 else { return }
            if expanded.contains(group.name) {
              expanded.remove(group.name)
            } else {
              expanded.insert(group.name)
            }
          } label: {
            HStack(spacing: 6) {
              Image(
                systemName: expanded.contains(group.name) ? "chevron.down" : "chevron.right"
              )
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.tertiary)
              .frame(width: 10)
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
            // Прозоре тло розтягує ціль кліку на порожнє місце рядка:
            // без нього клікаються лише самі написи.
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(group.members.count == 1)

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
      // PID лише під «Більше деталей»: у звичайному режимі це стовпчик цифр,
      // який нічого не пояснює, а місце під назву з'їдає.
      if showAllDetails {
        Text(String(member.pid))
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.tertiary)
          .frame(width: 42, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(member.label ?? member.name)
          .font(.system(size: 10))
          .lineLimit(1)
        // Назва сесії Claude або заголовок власного вікна процесу — те, що
        // відповідає на питання «а що це взагалі таке?».
        if let title = monitor.context(for: member) {
          Text(title)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
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

  // ── Сесії Claude Code ─────────────────────────────────────────────────

  /// Які розмови запущені, чим зайняті й скільки коштують.
  ///
  /// Дані з журналів самої Claude Code (`~/.claude/projects`), тому сесія
  /// видно навіть тоді, коли її процес загубився серед шести сотень інших.
  @ViewBuilder
  private var sessionsSection: some View {
    if !monitor.sessions.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          sectionTitle("Сесії Claude")
          Spacer()
          Text("\(monitor.sessions.filter { $0.pid != nil }.count) запущено")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        ForEach(monitor.sessions) { session in
          HStack(alignment: .top, spacing: 7) {
            Circle()
              .fill(stateColor(session.state, running: session.pid != nil))
              .frame(width: 6, height: 6)
              .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
              Text(session.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
              Text(sessionSubtitle(session))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
              if session.memory > 0 {
                Text(Format.bytes(session.memory))
                  .font(.system(size: 10, weight: .medium))
                  .monospacedDigit()
              }
              if let pid = session.pid {
                ActionButton(title: "Зупинити", destructive: true) {
                  confirmKill = Finding(
                    id: "session-\(pid)",
                    kind: .idleSessions,
                    title: session.title,
                    detail: "\(session.processCount) процесів, \(Format.bytes(session.memory))",
                    pids: [pid],
                    severity: 2)
                }
              }
            }
          }
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
        }
      }
    }
  }

  private func stateColor(_ state: ClaudeSessions.State, running: Bool) -> Color {
    guard running else { return .secondary.opacity(0.35) }
    switch state {
    case .working: return .orange
    case .waiting: return .green
    case .idle: return .secondary
    }
  }

  private func sessionSubtitle(_ session: Monitor.SessionRow) -> String {
    let project = URL(fileURLWithPath: session.directory).lastPathComponent
    guard session.pid != nil else {
      return "\(project) · не запущена · \(Format.duration(session.silence)) тому"
    }
    var parts = [project, session.state.label]
    if session.runtime > 0 {
      parts.append("відкрита \(Format.duration(session.runtime))")
    }
    if session.state != .working, session.silence > 60 {
      parts.append("тиша \(Format.duration(session.silence))")
    }
    return parts.joined(separator: " · ")
  }

  // ── Вкладки Chrome ────────────────────────────────────────────────────

  /// Вкладки окремим списком, а не підписом до процесів.
  ///
  /// Chrome не публікує зв'язку «вкладка ↔ процес-рендерер»: тридцять п'ять
  /// його процесів не розкладаються по вкладках. Показувати заголовок одного
  /// вікна біля кожного процесу означало б брехати, тож вкладки живуть тут.
  @ViewBuilder
  private var tabsSection: some View {
    if !monitor.browserTabs.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          sectionTitle("Вкладки Chrome")
          Spacer()
          Text("\(monitor.browserTabs.count)")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        // Показуємо активні вкладки перших вікон: саме вони щось споживають,
        // а повний список на сотню рядків тут нікому не потрібен.
        ForEach(visibleTabs) { tab in
          HStack(spacing: 6) {
            Circle()
              .fill(tab.active ? Color.accentColor : Color.secondary.opacity(0.35))
              .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
              Text(tab.title)
                .font(.system(size: 10))
                .lineLimit(1)
              if showAllDetails, !tab.host.isEmpty {
                Text(tab.host)
                  .font(.system(size: 9))
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
            }
            Spacer(minLength: 4)
          }
        }
        if monitor.browserTabs.count > visibleTabs.count {
          Text("…і ще \(monitor.browserTabs.count - visibleTabs.count)")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  /// Активні вкладки вперед — їх видно на екрані просто зараз; решта за
  /// порядком у вікнах, щоб список не перемішувався між оновленнями.
  private var visibleTabs: [BrowserTabs.Tab] {
    let byPosition = { (left: BrowserTabs.Tab, right: BrowserTabs.Tab) in
      left.windowIndex == right.windowIndex
        ? left.index < right.index : left.windowIndex < right.windowIndex
    }
    let active = monitor.browserTabs.filter(\.active).sorted(by: byPosition)
    let rest = monitor.browserTabs.filter { !$0.active }.sorted(by: byPosition)
    return Array((active + rest).prefix(showAllDetails ? 30 : 12))
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
