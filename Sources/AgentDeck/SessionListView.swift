import AgentDeckCore
import SwiftUI

struct SessionListView: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.sessions.isEmpty {
                Text("No active agent sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.sessions, id: \.key) { session in
                            SessionRow(
                                session: session,
                                needsAttention: model.needsAttention(session)
                            ) {
                                model.activate(session)
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("AgentDeck").font(.headline)
            Spacer()
            if model.attentionCount > 0 {
                Text("\(model.attentionCount) need attention")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            healthDot(ok: model.helperInstalled, label: "helper")
            healthDot(ok: model.claudeHooksInstalled, label: "claude")
            healthDot(ok: model.codexHooksInstalled, label: "codex")
            Spacer()
            if !(model.helperInstalled && model.claudeHooksInstalled
                && model.codexHooksInstalled) {
                Button("Install hooks") { _ = model.installHooks() }
                    .font(.caption)
            }
            Button("Quit") { NSApp.terminate(nil) }.font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func healthDot(ok: Bool, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .help(ok ? "\(label): installed" : "\(label): not installed")
    }
}

struct SessionRow: View {
    let session: SessionSnapshot
    let needsAttention: Bool
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
                    Text(session.projectName).font(.callout).lineLimit(1)
                    Text(session.projectPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    statePill
                    Text(session.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(needsAttention ? stateColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .help("Click to focus this iTerm pane")
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
