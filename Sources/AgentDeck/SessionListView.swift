import AgentDeckCore
import SwiftUI

struct SessionListView: View {
    @ObservedObject var model: SessionsModel
    /// ImageRenderer can't lay out ScrollView/LazyVStack, so the offscreen
    /// render harness swaps in a plain stack to inspect the real rows.
    var staticLayout = false
    /// -1 until a key is pressed: a highlight on row 0 that nobody asked for
    /// reads as "this row is special" rather than "keyboard cursor".
    @State private var selection: Int = -1

    private var rows: [SessionSnapshot] { model.visibleSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.sessions.count > 8 { filterField; Divider() }
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 360, maxWidth: 460)
        .focusable()
        // Focusable is required for onKeyPress, but macOS then paints a blue
        // focus ring around the container. The popover clips it into stray
        // blue bars at the top and bottom edges. This kills the ring (and,
        // being environment-based, the rings on the hidden ⌘1–9 buttons too)
        // while keeping key handling.
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { activateSelection() }
        .background(shortcutButtons)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var list: some View {
        if staticLayout {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.key) { index, session in
                    SessionRow(
                        session: session,
                        title: model.title(for: session),
                        subtitle: model.subtitle(for: session),
                        detail: model.detail(for: session),
                        unsupervised: model.isUnsupervised(session),
                        focusable: model.canFocus(session),
                        needsAttention: model.needsAttention(session),
                        selected: index == selection,
                        shortcutIndex: index < 9 ? index + 1 : nil
                    ) {}
                    Divider().padding(.leading, 12)
                }
            }
        } else {
            scrollingList
        }
    }

    private var scrollingList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.key) { index, session in
                        SessionRow(
                            session: session,
                            title: model.title(for: session),
                            subtitle: model.subtitle(for: session),
                            detail: model.detail(for: session),
                            unsupervised: model.isUnsupervised(session),
                            focusable: model.canFocus(session),
                            needsAttention: model.needsAttention(session),
                            selected: index == selection,
                            shortcutIndex: index < 9 ? index + 1 : nil
                        ) {
                            model.activate(session)
                        }
                        .id(index)
                        .contextMenu { contextMenu(for: session) }
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(rows.count) * 48 + 6, 460))
            .onChange(of: selection) { _, new in
                guard new >= 0 else { return }
                withAnimation(.none) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Filter sessions", text: $model.filterText)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel("Filter sessions by name or path")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if !model.helperInstalled || !model.claudeHooksInstalled
                || !model.codexHooksInstalled {
                Text("Hooks aren't installed yet")
                    .font(.callout)
                Text("Click “Install hooks” below, then start a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !model.filterText.isEmpty {
                Text("No sessions match “\(model.filterText)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active agent sessions")
                    .font(.callout)
                Text(
                    "Start `claude` or `codex` in iTerm2. Sessions started "
                    + "before hooks were installed appear after a restart."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AgentDeck").font(.headline)
            if !model.sessions.isEmpty {
                let claude = model.sessions.filter { $0.provider == .claude }.count
                Text("\(claude) CL · \(model.sessions.count - claude) CX")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.doneCount > 0 {
                Button {
                    model.acknowledgeAllDone()
                } label: {
                    Text("\(model.doneCount) done")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear finished sessions from the attention list")
            }
            if model.alertCount > 0 {
                Text("\(model.alertCount) need you")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .accessibilityLabel("\(model.alertCount) sessions need you")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func contextMenu(for session: SessionSnapshot) -> some View {
        Button("Focus pane") { model.activate(session) }
            .disabled(!model.canFocus(session))
        Button("Dismiss (don't focus)") { model.acknowledge(session) }
        Divider()
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.projectPath, forType: .string)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(
                nil, inFileViewerRootedAtPath: session.projectPath
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("hooks:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Setup health — are the lifecycle hooks installed? (Not session activity.)")
                healthDot(ok: model.helperInstalled, label: "helper")
                healthDot(ok: model.claudeHooksInstalled, label: "claude")
                healthDot(ok: model.codexHooksInstalled, label: "codex")
                Spacer()
                if !(model.helperInstalled && model.claudeHooksInstalled
                    && model.codexHooksInstalled) {
                    Button(model.isInstalling ? "Installing…" : "Install hooks") {
                        model.installHooks()
                    }
                    .font(.caption)
                    .disabled(model.isInstalling)
                }
                Menu {
                    Button("Copy diagnostics") { model.copyDiagnostics() }
                    Button("Open Automation settings") { model.openAutomationSettings() }
                    Divider()
                    Text("AgentDeck \(AgentDeckVersion.current)")
                    Button("Quit AgentDeck") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
            }
            if let problem = model.focusProblem {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem).font(.caption2)
                    if problem.contains("Automation") {
                        Button("Fix…") { model.openAutomationSettings() }
                            .font(.caption2)
                    }
                }
            }
            if let message = model.installMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Symbol + label, so health isn't encoded in colour alone.
    private func healthDot(ok: Bool, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) hooks \(ok ? "installed" : "not installed")")
        .help(ok ? "\(label): installed" : "\(label): not installed")
    }

    /// ⌘1–9 jump straight to a row.
    private var shortcutButtons: some View {
        ForEach(0..<min(rows.count, 9), id: \.self) { index in
            Button("") { model.activate(rows[index]) }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")), modifiers: .command
                )
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        if selection < 0 {
            selection = delta > 0 ? 0 : rows.count - 1
        } else {
            selection = max(0, min(rows.count - 1, selection + delta))
        }
        return .handled
    }

    private func activateSelection() -> KeyPress.Result {
        guard rows.indices.contains(selection) else { return .ignored }
        model.activate(rows[selection])
        return .handled
    }
}

struct SessionRow: View {
    let session: SessionSnapshot
    let title: String
    let subtitle: String
    let detail: String?
    let unsupervised: Bool
    let focusable: Bool
    let needsAttention: Bool
    let selected: Bool
    let shortcutIndex: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(session.provider == .claude ? "CL" : "CX")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(session.provider == .claude
                                  ? Color.orange.opacity(0.25)
                                  : Color.teal.opacity(0.25))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.callout).lineLimit(1)
                        if unsupervised {
                            Image(systemName: "lock.open.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("Running unsupervised — approvals are off")
                        }
                    }
                    HStack(spacing: 4) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail {
                            Text("· \(detail)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    statePill
                    Text(TimeFormat.compactAge(of: session.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .opacity(focusable ? 1 : 0.75)
        .help(focusable
              ? "Click to focus this iTerm pane"
              : "No iTerm pane recorded for this session — click just dismisses it")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(focusable ? "Focuses this session's iTerm pane" : "Dismisses it")
    }

    private var accessibilityLabel: String {
        var parts = [session.provider.displayName, title, session.state.rawValue]
        if let detail { parts.append(detail) }
        if unsupervised { parts.append("unsupervised") }
        parts.append(TimeFormat.compactAge(of: session.updatedAt))
        parts.append(subtitle)
        if let shortcutIndex { parts.append("command \(shortcutIndex)") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if selected {
            Color.accentColor.opacity(0.18)
        } else if needsAttention {
            stateColor.opacity(0.08)
        } else {
            Color.clear
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .ready: return .gray
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .error: return .red
        }
    }

    private var statePill: some View {
        Text(session.state.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(stateColor.opacity(needsAttention ? 0.35 : 0.15)))
    }
}
